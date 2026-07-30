import {
  parseStep,
  stepToApi,
  buildStepPayload,
  mergeStepEdit,
  slotAfterFlush,
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

    // step.knowledge (declaração de conhecimento da etapa, backfill do backend) sobrevive ao round-trip
    // mesmo SEM UI que o edite — o backend lê step['knowledge'] mas o formulário ainda não o conhece (PR 2).
    it('preserva step.knowledge no round-trip (backend -> form -> backend), sem UI que o edite', () => {
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

    // PR 2 INVERTE a precondição do PR 1: agora que a tela edita o campo, buildStepPayload EMITE knowledge.
    // A preservação ao editar deixa de vir da AUSÊNCIA da chave e passa a depender do draft ser semeado de
    // props.step.knowledge (testado no AiStepForm.spec). E o merge do saveStep passa a proteger as OUTRAS
    // chaves não emitidas (mergeStepEdit, abaixo).
    it('EMITE knowledge quando knowledgeQuery está preenchida (query trim + kinds por vírgula)', () => {
      const p = buildStepPayload({
        name: 'Viabilidade',
        knowledgeQuery: '  cidades atendidas  ',
        knowledgeKinds: 'documento, faq',
      });
      expect(p.knowledge).toEqual({
        query: 'cidades atendidas',
        kinds: ['documento', 'faq'],
      });
    });

    it('knowledgeQuery vazia OMITE a chave knowledge (não vira {query:""})', () => {
      expect(
        'knowledge' in buildStepPayload({ name: 'X', knowledgeQuery: '' })
      ).toBe(false);
      expect('knowledge' in buildStepPayload({ name: 'X' })).toBe(false);
    });

    it('kinds vazio -> knowledge com kinds: [] (o backend trata [] como todos)', () => {
      expect(
        buildStepPayload({
          name: 'X',
          knowledgeQuery: 'algo',
          knowledgeKinds: '',
        }).knowledge
      ).toEqual({ query: 'algo', kinds: [] });
    });

    // Cobertura do PR 1 que ficou por leitura (saveStep, linha 444): o merge preserva chaves AUSENTES no
    // payload. Extraído p/ testar sem montar o route-view. Agora protege legado/futuro (knowledge já é emitido).
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

  describe('buildStepPayload — slot_required no topo, nunca collect.required', () => {
    const base = { name: 'Email', instructions: 'grave o email_cliente' };

    it('Opcional -> slot_required=false; collect.required AUSENTE', () => {
      const p = buildStepPayload({
        ...base,
        hasSlot: true,
        slotRequired: false,
        collectAttribute: 'email_cliente',
      });
      expect(p.slot_required).toBe(false);
      expect(p.collect).toEqual({ attribute: 'email_cliente', type: 'text' });
      expect(p.collect.required).toBeUndefined();
    });

    it('Obrigatório -> slot_required=true', () => {
      expect(
        buildStepPayload({ ...base, hasSlot: true, slotRequired: true })
          .slot_required
      ).toBe(true);
    });

    it('editar a chave grava collect.attribute SEM collect.required', () => {
      const p = buildStepPayload({
        ...base,
        hasSlot: true,
        slotRequired: true,
        collectAttribute: 'cpf_cliente',
      });
      expect(p.collect.attribute).toBe('cpf_cliente');
      expect(p.collect.required).toBeUndefined();
    });

    it('slot inferido (sem chave manual) mantém collect null e grava slot_required do toggle', () => {
      const p = buildStepPayload({
        ...base,
        hasSlot: true,
        slotRequired: false,
        collectAttribute: '',
      });
      expect(p.collect).toBe(null);
      expect(p.slot_required).toBe(false);
    });

    // HOTFIX persistência: slot_required DESACOPLADO do hasSlot. Com o slot inferido AINDA não detectado
    // (hasSlot false — o radio fica escondido durante o POST infer_slot) e sem chave manual, o payload
    // preserva a escolha do radio (semeada do banco) em vez de nulificar em silêncio.
    it('detectedSlot ausente + manualSlot vazio preserva slot_required TRUE (falha se voltar a depender de hasSlot)', () => {
      const p = buildStepPayload({
        ...base,
        hasSlot: false,
        slotRequired: true,
        collectAttribute: '',
      });
      expect(p.collect).toBe(null);
      expect(p.slot_required).toBe(true);
    });

    it('detectedSlot ausente + manualSlot vazio preserva slot_required FALSE (falha se voltar a depender de hasSlot)', () => {
      const p = buildStepPayload({
        ...base,
        hasSlot: false,
        slotRequired: false,
        collectAttribute: '',
      });
      expect(p.collect).toBe(null);
      expect(p.slot_required).toBe(false);
    });

    it('NÃO escreve complete_when', () => {
      expect(
        'complete_when' in buildStepPayload({ ...base, hasSlot: true })
      ).toBe(false);
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

  describe('slotAfterFlush — (a) falha preserva o último slot conhecido', () => {
    it('falha/timeout mantém o último detectado (não vira "sem slot")', () => {
      expect(slotAfterFlush('email_cliente', { failed: true })).toBe(
        'email_cliente'
      );
    });

    it('sucesso usa o novo attribute', () => {
      expect(
        slotAfterFlush('email_cliente', { attribute: 'cpf_cliente' })
      ).toBe('cpf_cliente');
    });

    it('sucesso com attribute vazio LIMPA (é "sem slot" legítimo, não falha)', () => {
      expect(slotAfterFlush('email_cliente', { attribute: '' })).toBe('');
    });
  });
});
