import {
  parseStep,
  stepToApi,
  buildStepPayload,
  mergeStepEdit,
  reconcileSteps,
} from '../aiStepPayload';

// (1) reconciliação no 409: junta a edição do usuário com a mudança out-of-band do servidor, preservando
// as duas; ambíguo quando o array mudou de tamanho (Frente C). Prova de mutação por nome.
describe('reconcileSteps — merge no save defasado (409)', () => {
  const withUid = (arr, base) => arr.map((s, i) => ({ ...s, uid: base + i }));

  it('mescla: só a etapa que o usuário mudou sobrescreve; o resto fica com a versão FRESCA do servidor', () => {
    const original = withUid([{ name: 'A' }, { name: 'B' }, { name: 'C' }], 10);
    // usuário editou a etapa 0 (renomeou); o servidor ganhou on_complete na etapa 2 (console)
    const current = withUid([{ name: 'A2' }, { name: 'B' }, { name: 'C' }], 10);
    const fresh = withUid(
      [
        { name: 'A' },
        { name: 'B' },
        { name: 'C', on_complete: { action: 'handoff_human' } },
      ],
      99
    );

    const r = reconcileSteps(fresh, current, original);
    expect(r.status).toBe('merged');
    expect(r.steps[0].name).toBe('A2'); // edição do usuário preservada
    expect(r.steps[2].on_complete).toEqual({ action: 'handoff_human' }); // mudança do servidor preservada
  });

  it('uid não conta como diferença (o usuário não mudou nada -> tudo vem do servidor fresco)', () => {
    const original = withUid([{ name: 'A' }, { name: 'B' }], 1);
    const current = withUid([{ name: 'A' }, { name: 'B' }], 500); // uids diferentes, conteúdo igual
    const fresh = withUid(
      [{ name: 'A', on_complete: { action: 'close' } }, { name: 'B' }],
      900
    );
    const r = reconcileSteps(fresh, current, original);
    expect(r.status).toBe('merged');
    expect(r.steps[0].on_complete).toEqual({ action: 'close' }); // nada do usuário sobrescreve
  });

  it('AMBÍGUO quando o SERVIDOR mudou o tamanho do array (add/remove/reorder)', () => {
    const original = withUid([{ name: 'A' }, { name: 'B' }], 1);
    const current = withUid([{ name: 'A2' }, { name: 'B' }], 1);
    const fresh = withUid([{ name: 'A' }, { name: 'B' }, { name: 'C' }], 9); // servidor adicionou
    expect(reconcileSteps(fresh, current, original).status).toBe('ambiguous');
  });

  it('AMBÍGUO quando o USUÁRIO mudou o tamanho do array localmente', () => {
    const original = withUid([{ name: 'A' }, { name: 'B' }], 1);
    const current = withUid([{ name: 'A' }], 1); // usuário removeu
    const fresh = withUid([{ name: 'A' }, { name: 'B' }], 9);
    expect(reconcileSteps(fresh, current, original).status).toBe('ambiguous');
  });
});

describe('aiStepPayload', () => {
  // "Padrão ouro" (2026-08): instructions (1 textarea) virou objective/rules (2
  // campos). buildStepPayload NUNCA MAIS emite `instructions` — etapa antiga preserva o texto legado
  // via mergeStepEdit (chave ausente no payload = não sobrescreve). suggested_script ("Fala sugerida")
  // foi removido de novo (2026-08): mesmo como exemplo, o modelo tratava o texto entre aspas como
  // script literal — tom consistente agora vai no "Prompt base" do agente, não por etapa.
  describe('objective/rules — substituem instructions (1 textarea -> 2 campos)', () => {
    it('buildStepPayload SEMPRE emite objective (trim)', () => {
      const p = buildStepPayload({
        name: 'X',
        objective: '  Obter a cidade  ',
      });
      expect(p.objective).toBe('Obter a cidade');
    });

    it('buildStepPayload divide rules (textarea cru, uma por linha) em array, descartando linhas vazias', () => {
      const p = buildStepPayload({
        name: 'X',
        rules: 'Regra 1\n  Regra 2  \n\nRegra 3',
      });
      expect(p.rules).toEqual(['Regra 1', 'Regra 2', 'Regra 3']);
    });

    it('objective/rules ausentes -> defaults vazios ("" / [])', () => {
      const p = buildStepPayload({ name: 'X' });
      expect(p.objective).toBe('');
      expect(p.rules).toEqual([]);
    });

    it('buildStepPayload NUNCA emite a chave instructions (motor legado; etapa antiga sobrevive via merge)', () => {
      expect('instructions' in buildStepPayload({ name: 'X' })).toBe(false);
    });

    it('buildStepPayload NUNCA emite a chave suggested_script (campo removido)', () => {
      expect('suggested_script' in buildStepPayload({ name: 'X' })).toBe(false);
    });

    it('parseStep: etapa NOVA (objective já preenchido) preserva objective/rules', () => {
      const parsed = parseStep({
        name: 'Qualificação',
        objective: 'Obter a cidade',
        rules: ['Regra 1', 'Regra 2'],
      });
      expect(parsed.objective).toBe('Obter a cidade');
      expect(parsed.rules).toEqual(['Regra 1', 'Regra 2']);
    });

    // Migração: etapa ANTIGA (só instructions, objective ainda não existe) — o texto legado migra pro
    // campo Objetivo no form, nada se perde. Etapa que JÁ tem objective NÃO é tocada por instructions.
    it('parseStep: etapa ANTIGA (só instructions) semeia objective com o texto legado', () => {
      const parsed = parseStep({
        name: 'Cadastro',
        instructions: 'Peça e grave o CPF do cliente.',
      });
      expect(parsed.objective).toBe('Peça e grave o CPF do cliente.');
      expect(parsed.rules).toEqual([]);
    });

    it('parseStep: objective presente NÃO é sobrescrito por instructions legado', () => {
      const parsed = parseStep({
        name: 'X',
        objective: 'Novo formato',
        instructions: 'Texto antigo, deve ser ignorado',
      });
      expect(parsed.objective).toBe('Novo formato');
    });

    it('stepToApi normaliza rules: trim em cada item, remove vazios', () => {
      const api = stepToApi({
        name: 'X',
        rules: ['  Regra 1  ', '', '   ', 'Regra 2'],
      });
      expect(api.rules).toEqual(['Regra 1', 'Regra 2']);
    });

    it('round-trip (backend -> form -> backend) preserva objective/rules', () => {
      const fromBackend = {
        name: 'X',
        objective: 'Obter a cidade',
        rules: ['Regra 1'],
      };
      const roundTripped = stepToApi(parseStep(fromBackend));
      expect(roundTripped.objective).toBe('Obter a cidade');
      expect(roundTripped.rules).toEqual(['Regra 1']);
    });
  });

  describe('preservação de chaves (spread) — a classe de bug que fechou', () => {
    it('parseStep preserva collect/slot_required e QUALQUER campo desconhecido; normaliza + injeta uid', () => {
      const parsed = parseStep({
        name: 'Email',
        instructions: 'grave o email_cliente',
        collect: { attribute: 'email_cliente', type: 'email' },
        slot_required: false,
        complete_when: 'attribute_present',
        foo: 'bar', // campo sintético (backend futuro)
      });
      expect(parsed.collect).toEqual({
        attribute: 'email_cliente',
        type: 'email',
      });
      expect(parsed.slot_required).toBe(false);
      expect(parsed.foo).toBe('bar');
      expect(parsed.uid).toEqual(expect.any(Number));
    });

    it('stepToApi TIRA o uid e preserva o resto', () => {
      const api = stepToApi({
        uid: 7,
        name: '  Email  ',
        instructions: '  x  ',
        slot_required: true,
        foo: 'bar',
        group_delay_seconds: '5',
      });
      expect(api.uid).toBeUndefined();
      expect(api.name).toBe('Email');
      expect(api.slot_required).toBe(true);
      expect(api.foo).toBe('bar');
      expect(api.group_delay_seconds).toBe(5);
    });

    // ESTE é o teste que prova que a CLASSE do bug fechou (não um campo específico): um campo que a tela
    // NÃO edita sobrevive ao round-trip. Falharia com a lista fixa de 4 chaves; passa com o spread.
    it('round-trip (backend -> form -> backend) preserva um campo sintético que a tela não conhece', () => {
      const fromBackend = {
        name: 'X',
        foo: 'bar',
        collect: { attribute: 'y' },
      };
      const roundTripped = stepToApi(parseStep(fromBackend));
      expect(roundTripped.foo).toBe('bar');
      expect(roundTripped.collect).toEqual({ attribute: 'y' });
      expect(roundTripped.uid).toBeUndefined();
    });

    // step.knowledge é um campo LEGADO/MORTO: nunca foi lido pelo motor Python (substituído pela tool
    // agentic consultar_conhecimento) e a UI não o edita mais. Continua sobrevivendo ao round-trip só
    // pelo spread genérico (mesma proteção que qualquer chave desconhecida ganha) — inofensivo.
    it('preserva step.knowledge legado no round-trip (spread genérico, sem UI que o edite)', () => {
      const fromBackend = {
        name: 'Viabilidade',
        knowledge: { query: 'cidades atendidas', kinds: ['documento'] },
      };
      const roundTripped = stepToApi(parseStep(fromBackend));
      expect(roundTripped.knowledge).toEqual({
        query: 'cidades atendidas',
        kinds: ['documento'],
      });
    });

    // (Frente C / PR1) IDENTIDADE ESTÁVEL: o `id` do step (uuid do backend) sobrevive ao round-trip pelo
    // MESMO spread que preserva knowledge/collect — sem mudança no front. Prova de mutação: FALHA se alguém
    // passar o id a strip no parseStep/stepToApi e o backend reatribuir uuid a cada save (PR vira no-op).
    it('preserva o id do step no round-trip parseStep -> stepToApi (Frente C)', () => {
      const roundTripped = stepToApi(
        parseStep({ id: 'uuid-abc', name: 'Coleta' })
      );
      expect(roundTripped.id).toBe('uuid-abc');
    });

    it('mergeStepEdit preserva o id do step existente (buildStepPayload não emite id)', () => {
      const merged = mergeStepEdit(
        { id: 'uuid-9', name: 'X', collect: { attribute: 'a' } },
        { name: 'X editado', slot_required: true }
      );
      expect(merged.id).toBe('uuid-9');
    });

    // RAG virou tool agentic (consultar_conhecimento, sempre disponível, sem pré-configuração) —
    // buildStepPayload não conhece mais knowledgeQuery/knowledgeKinds e NUNCA emite a chave `knowledge`,
    // preservada ou não em etapas antigas (mergeStepEdit protege o que não é emitido, teste abaixo).
    it('NUNCA emite a chave knowledge (campo removido — RAG agora é tool, não config por etapa)', () => {
      expect('knowledge' in buildStepPayload({ name: 'X' })).toBe(false);
    });

    // Cobertura do PR 1 que ficou por leitura (saveStep, linha 444): o merge preserva chaves AUSENTES no
    // payload. Extraído p/ testar sem montar o route-view. Protege legado/futuro (knowledge nunca é emitido).
    it('mergeStepEdit preserva chaves do step existente que o payload NÃO emite', () => {
      const existing = {
        name: 'V',
        legado: 'sobrevive',
        collect: { attribute: 'a' },
      };
      const payload = { name: 'V', slot_required: true }; // sem legado/collect
      const merged = mergeStepEdit(existing, payload);
      expect(merged.legado).toBe('sobrevive'); // chave ausente no payload -> preservada
      expect(merged.collect).toEqual({ attribute: 'a' }); // idem
      expect(merged.slot_required).toBe(true); // o que o payload emite, sobrescreve
    });

    it('group_delay_seconds vazio vira null (não NaN)', () => {
      expect(
        stepToApi({ name: 'X', group_delay_seconds: '' }).group_delay_seconds
      ).toBe(null);
    });
  });

  // "DADOS PARA COLETA NA ETAPA": collectItems é uma LISTA agora, cada item com seu PRÓPRIO required —
  // slot_required (nível da etapa) não é mais emitido, cada dado carrega o seu (ver Ai::StepSlot.items
  // no backend, que já normaliza os dois formatos).
  describe('buildStepPayload — collectItems (um required por dado, não mais 1 por etapa)', () => {
    const base = { name: 'Dados do cliente' };

    it('um item obrigatório -> collect.items[0].required=true', () => {
      const p = buildStepPayload({
        ...base,
        collectItems: [
          { attribute: 'email_cliente', type: 'text', required: true },
        ],
      });
      expect(p.collect).toEqual({
        items: [{ attribute: 'email_cliente', type: 'text', required: true }],
      });
    });

    it('CPF obrigatório + e-mail opcional NA MESMA etapa: cada item com seu próprio required', () => {
      const p = buildStepPayload({
        ...base,
        collectItems: [
          { attribute: 'cpf_cliente', type: 'cpf', required: true },
          { attribute: 'email_cliente', type: 'email', required: false },
        ],
      });
      expect(p.collect.items[0]).toEqual({
        attribute: 'cpf_cliente',
        type: 'cpf',
        required: true,
      });
      expect(p.collect.items[1]).toEqual({
        attribute: 'email_cliente',
        type: 'email',
        required: false,
      });
    });

    it('item com dica de extração -> collect.items[].hint; sem dica, chave ausente (não vazia)', () => {
      const p = buildStepPayload({
        ...base,
        collectItems: [
          {
            attribute: 'cidade',
            type: 'text',
            required: true,
            hint: 'Cidade para instalar a internet',
          },
          { attribute: 'nome', type: 'text', required: true, hint: '' },
        ],
      });
      expect(p.collect.items[0].hint).toBe('Cidade para instalar a internet');
      expect('hint' in p.collect.items[1]).toBe(false);
    });

    it('item sem attribute (chave vazia) é descartado, não vira item quebrado no payload', () => {
      const p = buildStepPayload({
        ...base,
        collectItems: [
          { attribute: '  ', type: 'text', required: true },
          { attribute: 'nome', type: 'text', required: true },
        ],
      });
      expect(p.collect.items).toEqual([
        { attribute: 'nome', type: 'text', required: true },
      ]);
    });

    it('nenhum item -> collect: null (etapa informativa)', () => {
      expect(buildStepPayload({ ...base, collectItems: [] }).collect).toBe(
        null
      );
    });

    it('não emite slot_required (obsoleto — cada item carrega o seu required)', () => {
      const p = buildStepPayload({
        ...base,
        collectItems: [{ attribute: 'nome', type: 'text', required: true }],
      });
      expect('slot_required' in p).toBe(false);
    });

    it('NÃO escreve complete_when', () => {
      expect('complete_when' in buildStepPayload(base)).toBe(false);
    });
  });

  // (B2) choice: as opções vêm de uma lista fixa OU do resultado de uma ferramenta (domínio dinâmico) —
  // agora configurável POR ITEM, não mais uma vez pra etapa inteira.
  describe('buildStepPayload — choice: fonte das opções (lista fixa vs ferramenta), por item', () => {
    const item = (overrides = {}) => ({
      attribute: 'periodo_reservado',
      type: 'choice',
      required: true,
      ...overrides,
    });

    it('fonte "fixed" grava options da lista digitada, SEM domain_from_tool', () => {
      const p = buildStepPayload({
        name: 'Período',
        collectItems: [item({ source: 'fixed', options: 'Manhã\nTarde' })],
      });
      expect(p.collect.items[0].options).toEqual(['Manhã', 'Tarde']);
      expect('domain_from_tool' in p.collect.items[0]).toBe(false);
    });

    it('fonte "tool" grava domain_from_tool (o NOME) e LIMPA options (=[])', () => {
      const p = buildStepPayload({
        name: 'Período',
        collectItems: [
          item({
            source: 'tool',
            domainTool: 'consultar_periodos',
            // lista fixa antiga presente no draft: deve ser descartada, não vazar
            options: 'Manhã\nTarde',
          }),
        ],
      });
      expect(p.collect.items[0].domain_from_tool).toBe('consultar_periodos');
      expect(p.collect.items[0].options).toEqual([]);
    });

    it('fonte "tool" sem ferramenta escolhida cai na lista fixa (não grava domain_from_tool vazio)', () => {
      const p = buildStepPayload({
        name: 'Período',
        collectItems: [
          item({ source: 'tool', domainTool: '', options: 'Manhã' }),
        ],
      });
      expect('domain_from_tool' in p.collect.items[0]).toBe(false);
      expect(p.collect.items[0].options).toEqual(['Manhã']);
    });

    it('voltar de "tool" para "fixed" NÃO deixa domain_from_tool no payload (limpo pela reconstrução do item)', () => {
      const p = buildStepPayload({
        name: 'Período',
        collectItems: [
          item({
            source: 'fixed',
            domainTool: 'consultar_periodos',
            options: 'Manhã',
          }), // resquício ignorado
        ],
      });
      expect('domain_from_tool' in p.collect.items[0]).toBe(false);
    });

    it('domain_from_tool só existe em type=choice (type=text nunca emite, mesmo com source=tool)', () => {
      const p = buildStepPayload({
        name: 'X',
        collectItems: [
          {
            attribute: 'periodo_reservado',
            type: 'text',
            required: true,
            source: 'tool',
            domainTool: 'consultar_periodos',
          },
        ],
      });
      expect(p.collect.items[0]).toEqual({
        attribute: 'periodo_reservado',
        type: 'text',
        required: true,
      });
    });

    it('dois itens choice INDEPENDENTES na mesma etapa: cada um com sua própria fonte de opções', () => {
      const p = buildStepPayload({
        name: 'Dois selects',
        collectItems: [
          item({
            attribute: 'periodo',
            source: 'fixed',
            options: 'Manhã\nTarde',
          }),
          item({
            attribute: 'plano',
            source: 'tool',
            domainTool: 'consultar_planos',
          }),
        ],
      });
      expect(p.collect.items[0].options).toEqual(['Manhã', 'Tarde']);
      expect(p.collect.items[1].domain_from_tool).toBe('consultar_planos');
    });
  });

  describe('buildStepPayload — on_complete (desfecho declarado, (b)-core)', () => {
    const base = { name: 'Finalização' };

    // reason é CONSTANTE do contrato p/ handoff_human -> alimenta REASON_LABELS['conclusao'] no card do
    // atendente. A UI não coletava reason e o desfecho salvo pela tela ficava SEM ele (v34: {action,team_id}
    // sem reason). Falha por mutação se buildStepPayload parar de emitir reason em handoff_human.
    it('handoff_human com team_id -> { action, reason: "conclusao", team_id }', () => {
      const p = buildStepPayload({
        ...base,
        onCompleteAction: 'handoff_human',
        onCompleteTeamId: 5,
      });
      expect(p.on_complete).toEqual({
        action: 'handoff_human',
        reason: 'conclusao',
        team_id: 5,
      });
    });

    it('handoff_human SEM team_id ainda emite reason: "conclusao"', () => {
      const p = buildStepPayload({
        ...base,
        onCompleteAction: 'handoff_human',
      });
      expect(p.on_complete).toEqual({
        action: 'handoff_human',
        reason: 'conclusao',
      });
    });

    // close resolve a conversa e handoff_ai roteia p/ outra IA: nenhum gera card humano com motivo, então
    // NÃO carregam reason (não inventar contrato sem consumidor).
    it('close -> { action: "close" } (sem reason/team_id/target)', () => {
      expect(
        buildStepPayload({ ...base, onCompleteAction: 'close' }).on_complete
      ).toEqual({ action: 'close' });
    });

    it('handoff_ai -> { action, target } (sem reason)', () => {
      const p = buildStepPayload({
        ...base,
        onCompleteAction: 'handoff_ai',
        onCompleteTarget: 'Nova',
      });
      expect(p.on_complete).toEqual({ action: 'handoff_ai', target: 'Nova' });
    });

    it('team_id só entra em handoff_human; target só em handoff_ai (não vazam entre ações)', () => {
      expect(
        buildStepPayload({
          ...base,
          onCompleteAction: 'close',
          onCompleteTeamId: 5,
          onCompleteTarget: 'Nova',
        }).on_complete
      ).toEqual({ action: 'close' });
    });

    // Ação vazia LIMPA (on_complete: null), NÃO omite — senão o mergeStepEdit preservaria um backfill que o
    // usuário acabou de apagar. Mesmo contrato do collect. Falha por mutação se voltar a omitir a chave.
    it('ação vazia -> on_complete: null (LIMPA; não omite)', () => {
      const p = buildStepPayload({ ...base, onCompleteAction: '' });
      expect('on_complete' in p).toBe(true);
      expect(p.on_complete).toBe(null);
    });

    // A armadilha de #306/knowledge: com o draft SEMEADO de props.step.on_complete, salvar SEM tocar no
    // campo reemite o MESMO valor. (No AiStepForm o seeding é testado; aqui provamos que os params semeados
    // produzem o mesmo on_complete — o merge do saveStep então preserva o backfill.)
    it('draft semeado (salvar sem tocar) reemite o on_complete com o reason preenchido (backfill preservado + curado)', () => {
      // Semeado a partir de um on_complete LEGADO (sem reason, como o v34/console). Reemitir preenche o
      // reason do contrato — não perde team_id e ainda CURA o motivo ausente.
      const seeded = { action: 'handoff_human', team_id: 7 };
      const p = buildStepPayload({
        ...base,
        onCompleteAction: seeded.action,
        onCompleteTeamId: seeded.team_id,
      });
      expect(p.on_complete).toEqual({
        action: 'handoff_human',
        reason: 'conclusao',
        team_id: 7,
      });
    });
  });
});
