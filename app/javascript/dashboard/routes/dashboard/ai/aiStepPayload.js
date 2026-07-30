// (De)serialização de uma ETAPA do playbook entre o backend (jsonb) e o form.
//
// A classe de bug que isto conserta: parseSteps/buildPayload RECONSTRUÍAM a etapa com 4 chaves fixas
// (name/instructions/automations/group_delay_seconds), então qualquer campo que o backend lê — collect,
// slot_required (Gap 2), e futuros — morria no primeiro save (e no load). Aqui usamos SPREAD-e-sobrescreve:
// preserva tudo, normaliza só o que a tela edita. Campo novo do backend sobrevive sem tocar em nenhuma lista.

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
      instructions: '',
      automations: [],
      group_delay_seconds: '',
    };
  }
  return {
    ...s,
    uid: nextStepUid(),
    name: s.name || '',
    instructions: s.instructions || s.objective || '',
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
    instructions: (s.instructions || '').trim(),
    automations: Array.isArray(s.automations) ? s.automations : [],
    group_delay_seconds:
      s.group_delay_seconds === '' || s.group_delay_seconds == null
        ? null
        : Number(s.group_delay_seconds),
  };
};

// Payload que o AiStepForm devolve no save. Regras (Gaps 1–3 no backend):
//  - slot_required SEMPRE no nível da etapa, NUNCA collect.required (o Gap 2 desacoplou; não reacoplar);
//  - chave manual -> collect = { attribute, type[, options] } SEM required;
//  - slot_required reflete SEMPRE a escolha do radio (draft.slotRequired, semeado do banco), DESACOPLADO
//    do estado da inferência. Antes: `hasSlot ? !!slotRequired : null` — num slot INFERIDO (collect null)
//    `hasSlot` dependia do POST infer_slot ter resolvido no save; se não resolvesse, a política do usuário
//    virava null em silêncio (o radio nem chegava a ser renderizado — v-if="hasSlot"). slot_required numa
//    etapa SEM slot é inofensivo: o Ai::StepResolver retorna antes de consultar optional? quando
//    Ai::StepSlot.attribute(step) é nil. (Custo: o antigo "limpar slot_required legado ao ficar sem slot"
//    sai; resíduo de baixo risco — remover o slot com false e a inferência reachá-lo depois.)
//  - NÃO escreve complete_when (morto no backend pós-Gap 2; legado sobrevive pelo spread, intocado);
//  - knowledge: EMITIDO quando knowledgeQuery está preenchida -> { query, kinds: [...] } (kinds separado
//    por vírgula; vazio = todos). query vazia => a chave knowledge SAI do payload (não vira {query:""}).
//    Input DIRETO do usuário — NÃO depende de estado assíncrono (não repetir o acoplamento do hasSlot/#306).
//  - on_complete (desfecho declarado, (b)-core): action vazia => on_complete = null (LIMPA — como collect;
//    NÃO omitir, senão o mergeStepEdit preservaria um backfill que o usuário acabou de apagar). action
//    presente => { action[, team_id em handoff_human][, target em handoff_ai] } (reason fica com o default
//    'conclusao' do backend). SEMEADO de props.step.on_complete no form — editar sem tocar preserva o valor
//    (a mesma armadilha de #306/knowledge: emitir sem semear apagaria o backfill em silêncio).
export const buildStepPayload = ({
  name,
  instructions,
  groupDelaySeconds,
  automations = [],
  collectAttribute = '',
  collectType = 'text',
  collectOptions = '',
  slotRequired = true,
  knowledgeQuery = '',
  knowledgeKinds = '',
  onCompleteAction = '',
  onCompleteTeamId = '',
  onCompleteTarget = '',
}) => {
  const attribute = (collectAttribute || '').trim();
  const payload = {
    name: (name || '').trim(),
    instructions: (instructions || '').trim(),
    group_delay_seconds: groupDelaySeconds,
    automations: automations.map(a => ({ type: a.type, params: a.params })),
    slot_required: !!slotRequired,
  };
  if (attribute) {
    payload.collect = { attribute, type: collectType || 'text' };
    if (collectType === 'choice') {
      payload.collect.options = (collectOptions || '')
        .split('\n')
        .map(o => o.trim())
        .filter(Boolean);
    }
  } else {
    payload.collect = null;
  }
  const query = (knowledgeQuery || '').trim();
  if (query) {
    payload.knowledge = {
      query,
      kinds: (knowledgeKinds || '')
        .split(',')
        .map(k => k.trim())
        .filter(Boolean),
    };
  }
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

// Merge do saveStep (AiDepartmentDetail): a etapa editada = a existente sobrescrita SÓ pelas chaves que o
// payload emite. Chaves que buildStepPayload NÃO emite (campos legados/futuros do backend) sobrevivem pelo
// spread. Extraído para testar essa preservação sem montar o route-view inteiro (a cobertura do PR 1, que
// ficou verificada só por leitura). Agora que knowledge É emitido, isto protege as OUTRAS chaves ausentes.
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

// (a) Flush da inferência ao salvar: decide o slot a usar a partir do resultado da RE-inferência.
// Falha/timeout (`failed`) MANTÉM o último slot conhecido — uma falha de rede não pode transformar uma
// etapa de coleta em informativa em silêncio. Sucesso com attribute vazio LIMPA (é "sem slot" legítimo,
// não falha). É a mesma falha invisível que o Estado B existe para eliminar.
export const slotAfterFlush = (lastKnown, inferResult) => {
  if (!inferResult || inferResult.failed) return lastKnown || '';
  return inferResult.attribute || '';
};
