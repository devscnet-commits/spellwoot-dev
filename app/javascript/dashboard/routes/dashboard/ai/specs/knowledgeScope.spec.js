import {
  scopeOptionLabel,
  sourceScope,
  buildScopeChips,
  buildScopeOptions,
} from '../knowledgeScope';

// Fusão Departamento -> Agente (19/08): o endpoint `agents` devolve { id, name } — um nome só
// por agente (antes havia name do dept + agent do assistant, que podiam divergir e exigiam
// desambiguação "Agente · Dept"; esse caso não existe mais).
describe('knowledgeScope', () => {
  describe('scopeOptionLabel', () => {
    it('retorna o nome do agente', () => {
      expect(scopeOptionLabel({ id: 1, name: 'Suporte' })).toBe('Suporte');
    });

    it('não quebra com valor nulo/indefinido', () => {
      expect(scopeOptionLabel(null)).toBe('');
      expect(scopeOptionLabel(undefined)).toBe('');
    });
  });

  describe('sourceScope', () => {
    const agents = [
      { id: 10, name: 'Maya v5.0' },
      { id: 20, name: 'Joana v2' },
    ];

    it('classifica como compartilhado quando ai_agent_id é nulo', () => {
      expect(sourceScope({ ai_agent_id: null }, agents)).toEqual({
        status: 'shared',
      });
    });

    it('trata source nulo como compartilhado (sem quebrar)', () => {
      expect(sourceScope(null, agents)).toEqual({ status: 'shared' });
    });

    it('classifica como escopado e traz o label do agente quando ele existe', () => {
      expect(sourceScope({ ai_agent_id: 20 }, agents)).toEqual({
        status: 'scoped',
        label: 'Joana v2',
      });
    });

    it('classifica como órfão quando o agente não existe mais na lista', () => {
      expect(sourceScope({ ai_agent_id: 999 }, agents)).toEqual({
        status: 'orphan',
      });
    });

    it('não confunde órfão (agente setado, some da lista) com compartilhado (nulo)', () => {
      const orphan = sourceScope({ ai_agent_id: 999 }, agents);
      const shared = sourceScope({ ai_agent_id: null }, agents);
      expect(orphan.status).toBe('orphan');
      expect(shared.status).toBe('shared');
      expect(orphan.status).not.toBe(shared.status);
    });
  });

  describe('buildScopeChips', () => {
    const agents = [
      { id: 10, name: 'Maya v5.0' },
      { id: 20, name: 'Joana v2' },
    ];
    const labels = {
      all: 'Todos',
      shared: 'Compartilhado',
      orphan: 'Fonte órfã',
    };

    it('lista TODOS os agentes da conta, mesmo os sem nenhuma fonte (contagem 0)', () => {
      // Só o agente 10 tem fonte; o agente 20 (novo/vazio) precisa aparecer com count 0.
      const sources = [
        { ai_agent_id: 10 },
        { ai_agent_id: 10 },
        { ai_agent_id: null },
      ];
      const chips = buildScopeChips(agents, sources, labels);
      const joana = chips.find(c => c.value === '20');
      expect(joana).toBeTruthy();
      expect(joana.count).toBe(0);
      // não deriva dos sources: os 2 agentes aparecem mesmo com só 1 tendo fonte
      expect(
        chips.filter(c => c.value === '10' || c.value === '20')
      ).toHaveLength(2);
    });

    it('conta as fontes por agente, compartilhado e total corretamente', () => {
      const sources = [
        { ai_agent_id: 10 },
        { ai_agent_id: 20 },
        { ai_agent_id: 20 },
        { ai_agent_id: null },
      ];
      const chips = buildScopeChips(agents, sources, labels);
      const by = v => chips.find(c => c.value === v);
      expect(by('all').count).toBe(4);
      expect(by('shared').count).toBe(1);
      expect(by('10').count).toBe(1);
      expect(by('20').count).toBe(2);
    });

    it('sempre começa por Todos e Compartilhado, nessa ordem', () => {
      const chips = buildScopeChips(agents, [], labels);
      expect(chips[0].value).toBe('all');
      expect(chips[1].value).toBe('shared');
    });

    it('mostra o chip Fonte órfã (com contagem) só quando há fonte apontando p/ agente inexistente', () => {
      const semOrfa = buildScopeChips(agents, [{ ai_agent_id: 10 }], labels);
      expect(semOrfa.some(c => c.value === 'orphan')).toBe(false);

      const comOrfa = buildScopeChips(
        agents,
        [{ ai_agent_id: 999 }, { ai_agent_id: 999 }],
        labels
      );
      const orphan = comOrfa.find(c => c.value === 'orphan');
      expect(orphan).toBeTruthy();
      expect(orphan.count).toBe(2);
    });

    it('não quebra com listas vazias/indefinidas', () => {
      expect(buildScopeChips(undefined, undefined, labels)).toHaveLength(2);
      expect(buildScopeChips([], [], labels)[0].count).toBe(0);
    });
  });

  describe('buildScopeOptions', () => {
    const agents = [
      { id: 10, name: 'Maya v5.0' },
      { id: 20, name: 'Joana v2' },
    ];
    const labels = {
      all: 'Todos',
      shared: 'Compartilhado',
      orphan: 'Fonte órfã',
    };

    it('devolve options do Select ({ value, label }) com a contagem embutida no label', () => {
      const sources = [
        { ai_agent_id: 10 },
        { ai_agent_id: 10 },
        { ai_agent_id: null },
      ];
      const options = buildScopeOptions(agents, sources, labels);

      expect(options[0]).toEqual({ value: 'all', label: 'Todos (3)' });
      expect(options[1]).toEqual({
        value: 'shared',
        label: 'Compartilhado (1)',
      });
      expect(options.find(o => o.value === '10')).toEqual({
        value: '10',
        label: 'Maya v5.0 (2)',
      });
      // agente vazio continua aparecendo, com (0)
      expect(options.find(o => o.value === '20')).toEqual({
        value: '20',
        label: 'Joana v2 (0)',
      });
    });

    it('preserva os values usados pela filtragem (all|shared|orphan|<agentId>)', () => {
      const options = buildScopeOptions(agents, [{ ai_agent_id: 999 }], labels);
      expect(options.map(o => o.value)).toEqual([
        'all',
        'shared',
        '10',
        '20',
        'orphan',
      ]);
      expect(options.find(o => o.value === 'orphan').label).toBe(
        'Fonte órfã (1)'
      );
    });
  });
});
