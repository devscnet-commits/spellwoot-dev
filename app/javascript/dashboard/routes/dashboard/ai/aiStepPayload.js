// (De)serialização de uma ETAPA do playbook entre o backend (jsonb) e o form.
//
// A classe de bug que isto conserta: parseSteps/buildPayload RECONSTRUÍAM a etapa com 4 chaves fixas
// (name/instructions/automations/group_delay_seconds), então qualquer campo que o backend lê — collect,
// slot_required (Gap 2), e futuros — morria no primeiro save (e no load). Aqui usamos SPREAD-e-sobrescreve:
// preserva tudo, normaliza só o que a tela edita. Campo novo do backend sobrevive sem tocar em nenhuma lista.
//
// "Padrão ouro" (2026-08): a instrução da etapa deixou de ser 1 textarea (`instructions`) e virou 2 campos
// estruturados — objective (string), rules (array) — pro motor Python/Agêntico
// seguir melhor (Ai::StepInstructionText no backend). buildStepPayload NUNCA MAIS emite `instructions`: uma
// etapa ANTIGA que ainda só tem instructions mantém o texto legado intacto (sobrevive pelo mergeStepEdit,
// que só sobrescreve as chaves que o payload emite); Ai::StepInstructionText cai nesse fallback quando os 2
// campos novos estão vazios. parseStep semeia objective a partir de instructions quando objective ainda não
// existe, pra migrar o texto pro form sem perder o que já estava escrito.
// suggested_script ("Fala sugerida") foi REMOVIDO (2026-08): mesmo rotulado como exemplo, o modelo tratava
// o texto entre aspas como script literal. Tom/abordagem consistente agora só vai no "Prompt base" do
// agente (global), não mais por etapa — parseStep/stepToApi/buildStepPayload não conhecem mais o campo.

let stepUid = 0;
export const nextStepUid = () => {
  stepUid += 1;
  return stepUid;
};

// backend -> form: preserva todas as chaves; normaliza os campos editáveis; injeta o uid (client-only).
export const parseStep = s => {
  if (typeof s === 'string') {
    return {
      uid: nextStepUid(),
      name: s,
      objective: '',
      rules: [],
      automations: [],
      group_delay_seconds: '',
    };
  }
  return {
    ...s,
    uid: nextStepUid(),
    name: s.name || '',
    // Migração: etapa ANTIGA (só instructions, sem objective) carrega o texto legado pro campo Objetivo —
    // nada se perde; o admin edita/divide dali. Etapa que JÁ tem objective não é tocada por instructions.
    objective: s.objective || s.instructions || '',
    rules: Array.isArray(s.rules) ? s.rules : [],
    automations: Array.isArray(s.automations) ? s.automations : [],
    group_delay_seconds: s.group_delay_seconds ?? '',
  };
};

// form -> backend: preserva todas as chaves; TIRA o uid (só cliente); normaliza os editáveis.
export const stepToApi = s => {
  const { uid, ...rest } = s;
  return {
    ...rest,
    name: (s.name || '').trim(),
    objective: (s.objective || '').trim(),
    rules: Array.isArray(s.rules)
      ? s.rules.map(r => (r || '').toString().trim()).filter(Boolean)
      : [],
    automations: Array.isArray(s.automations) ? s.automations : [],
    group_delay_seconds:
      s.group_delay_seconds === '' || s.group_delay_seconds == null
        ? null
        : Number(s.group_delay_seconds),
  };
};

// Payload que o AiStepForm devolve no save. Regras (Gaps 1–3 no backend):
//  - objective/rules SEMPRE emitidos (mesma convenção de name — trim, array normalizado);
//    `instructions` NUNCA é emitido (etapa antiga preserva o texto legado via mergeStepEdit —
//    buildStepPayload não conhece mais esse campo);
//  - collect = { items: [...] } — um item por dado (ver #buildCollectItem), CADA um com seu PRÓPRIO
//    required; [] => collect: null. slot_required (nível da etapa, formato ANTIGO) não é mais emitido —
//    substituído pelo required por item;
//  - NÃO escreve complete_when (morto no backend pós-Gap 2; legado sobrevive pelo spread, intocado);
//  - NÃO escreve mais `knowledge` (campo "consultar conhecimento antes de responder" + "filtrar por
//    tipo"): substituído pela tool agentic consultar_conhecimento (Ai::PythonOrchestratorClient),
//    sempre disponível em toda etapa — a IA decide quando buscar, sem pré-configuração de query/kind.
//    O campo nunca chegou a ser lido pelo motor Python (só existia na tela); etapas antigas que ainda
//    têm `knowledge` no jsonb mantêm o valor morto pelo spread — inofensivo, nada mais lê essa chave.
//  - on_complete (desfecho declarado, (b)-core): action vazia => on_complete = null (LIMPA — como collect;
//    NÃO omitir, senão o mergeStepEdit preservaria um backfill que o usuário acabou de apagar). action
//    presente => { action[, team_id em handoff_human][, target em handoff_ai] } (reason fica com o default
//    'conclusao' do backend). SEMEADO de props.step.on_complete no form — editar sem tocar preserva o valor
//    (a mesma armadilha de #306/knowledge: emitir sem semear apagaria o backfill em silêncio).
// Um item de "DADOS PARA COLETA NA ETAPA" (Ai::StepSlot.items no backend): CADA dado com SEU PRÓPRIO
// type/options/required/hint, em vez de 1 collect por etapa inteira compartilhado entre todos os dados
// (o que forçava CPF/e-mail/nome na mesma etapa a cair no mesmo tipo, ou a virar 3 etapas separadas).
// item: {attribute, type, options (textarea cru, 1 por linha — mesma convenção de sempre), source
// ('fixed'|'tool'), domainTool, required (bool), hint}. attribute vazio descarta o item (a UI não deixa
// isso acontecer — o botão de adicionar já exige a chave — mas não é papel do payload validar UI).
const buildCollectItem = item => {
  const attribute = (item?.attribute || '').trim();
  if (!attribute) return null;

  const built = {
    attribute,
    type: item.type || 'text',
    required: !!item.required,
  };
  const hint = (item.hint || '').trim();
  if (hint) built.hint = hint;

  if (built.type === 'choice') {
    const tool = (item.domainTool || '').trim();
    if (item.source === 'tool' && tool) {
      // Domínio dinâmico: a ferramenta é o validador ÚNICO. options=[] LIMPA qualquer lista fixa antiga
      // (senão o spread de collect a preservaria) — o backend ignora options quando domain_from_tool está
      // presente, mas deixar lista morta confunde a próxima edição.
      built.options = [];
      built.domain_from_tool = tool;
    } else {
      built.options = (item.options || '')
        .split('\n')
        .map(o => o.trim())
        .filter(Boolean);
    }
  }
  return built;
};

export const buildStepPayload = ({
  name,
  objective = '',
  // Texto bruto do textarea, UMA regra por linha (a mesma convenção de collectOptions) —
  // dividido e limpo aqui, não no componente.
  rules = '',
  groupDelaySeconds,
  automations = [],
  // Lista de dados que a etapa coleta (ver #buildCollectItem) — [] => etapa informativa, collect: null.
  // slot_required (nível da etapa) NÃO é mais emitido: era o único "obrigatório" pra 1 dado por etapa;
  // cada item agora carrega o SEU PRÓPRIO `required` (Gap 2, formato novo — ver Ai::StepSlot no backend).
  // Etapa antiga salva antes desta mudança mantém slot_required por spread (mergeStepEdit); é lido só
  // pelo formato ANTIGO de collect (Ai::StepSlot.legacy_required) — inofensivo, nunca mais escrito daqui.
  collectItems = [],
  onCompleteAction = '',
  onCompleteTeamId = '',
  onCompleteTarget = '',
}) => {
  const payload = {
    name: (name || '').trim(),
    objective: (objective || '').trim(),
    rules: (rules || '')
      .split('\n')
      .map(r => r.trim())
      .filter(Boolean),
    group_delay_seconds: groupDelaySeconds,
    automations: automations.map(a => ({ type: a.type, params: a.params })),
  };
  const items = (collectItems || []).map(buildCollectItem).filter(Boolean);
  payload.collect = items.length ? { items } : null;

  const action = (onCompleteAction || '').trim();
  if (action) {
    const onComplete = { action };
    if (action === 'handoff_human') {
      // reason é CONSTANTE do contrato (NÃO campo de usuário): alimenta REASON_LABELS['conclusao'] no card
      // do atendente (Ai::HandoffSummaryGenerator). Só handoff_human gera card humano com motivo — close
      // resolve e handoff_ai roteia p/ outra IA, nenhum consome reason. O backend já faz default 'conclusao'
      // (force_conclusion: info['reason'].presence || 'conclusao'), então isto NÃO conserta um card quebrado;
      // completa o contrato GRAVADO (todo desfecho salvo pela tela passa a ter reason, como os do console) e
      // não depende do default silencioso — se o backend mudar o default, o valor gravado continua correto.
      onComplete.reason = 'conclusao';
      if (onCompleteTeamId) onComplete.team_id = onCompleteTeamId;
    }
    if (action === 'handoff_ai' && onCompleteTarget)
      onComplete.target = onCompleteTarget;
    payload.on_complete = onComplete;
  } else {
    payload.on_complete = null; // LIMPA (mergeStepEdit sobrescreve o backfill anterior); não omitir
  }
  return payload;
};

// Merge do saveStep (AiAgentBehaviorPanel): a etapa editada = a existente sobrescrita SÓ pelas chaves que o
// payload emite. Chaves que buildStepPayload NÃO emite (campos legados/futuros do backend) sobrevivem pelo
// spread. Extraído para testar essa preservação sem montar o route-view inteiro (a cobertura do PR 1, que
// ficou verificada só por leitura). Protege qualquer chave que buildStepPayload não emite (ex.: knowledge legado).
export const mergeStepEdit = (existing, payload) => ({
  ...existing,
  ...payload,
});

// (1) Reconciliação de steps no 409 (save defasado): junta a versão do usuário (`current`) com a do
// servidor (`fresh`), preservando AS DUAS. Só as etapas que o usuário REALMENTE mudou (diferem de
// `original`, o estado carregado) sobrescrevem a etapa correspondente do servidor; as demais posições ficam
// com a versão FRESCA (a mudança out-of-band — ex.: on_complete escrito por console em OUTRA etapa).
// AMBÍGUO quando o array mudou de TAMANHO (servidor OU usuário adicionou/removeu/reordenou): sem identidade
// estável de etapa, casar por índice deixa de ser seguro — é exatamente o que a Frente C resolve. Retorna
// { status: 'merged', steps } ou { status: 'ambiguous' }.
export const reconcileSteps = (fresh, current, original) => {
  if (
    !Array.isArray(fresh) ||
    !Array.isArray(current) ||
    !Array.isArray(original)
  )
    return { status: 'ambiguous' };
  // tamanho diferente em QUALQUER lado (servidor mexeu na estrutura, ou o usuário mexeu localmente) =>
  // reaplicar por índice misatribuiria. Ambíguo.
  if (fresh.length !== original.length || current.length !== original.length)
    return { status: 'ambiguous' };

  const strip = s => {
    const { uid, ...rest } = s || {};
    return rest;
  };
  const userChanged = i =>
    JSON.stringify(strip(current[i])) !== JSON.stringify(strip(original[i]));
  const steps = fresh.map((freshStep, i) =>
    userChanged(i) ? current[i] : freshStep
  );
  return { status: 'merged', steps };
};
