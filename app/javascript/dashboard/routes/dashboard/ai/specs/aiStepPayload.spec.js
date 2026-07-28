import {
  parseStep,
  stepToApi,
  buildStepPayload,
  slotAfterFlush,
} from '../aiStepPayload';

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

    // buildStepPayload NÃO emite a chave knowledge -> o merge de saveStep ({...form.steps[i], ...payload})
    // preserva o valor do banco ao editar a etapa. Falha (bomba do backfill) se ela passar a emitir knowledge.
    it('buildStepPayload NÃO emite a chave knowledge (o merge de saveStep preserva o backfill)', () => {
      expect(
        'knowledge' in buildStepPayload({ name: 'X', hasSlot: true })
      ).toBe(false);
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
