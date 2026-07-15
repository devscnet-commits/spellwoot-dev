import {
  scopeOptionLabel,
  sourceScope,
  buildScopeChips,
  buildScopeOptions,
} from '../knowledgeScope';

describe('knowledgeScope', () => {
  describe('scopeOptionLabel', () => {
    it('retorna o nome do dept quando não há agente', () => {
      expect(scopeOptionLabel({ id: 1, name: 'Suporte', agent: null })).toBe(
        'Suporte'
      );
    });

    it('colapsa para um nome só quando dept e agente coincidem', () => {
      expect(
        scopeOptionLabel({ id: 1, name: 'Maya v5.0', agent: 'Maya v5.0' })
      ).toBe('Maya v5.0');
    });

    it('desambigua "Agente · Dept" quando os nomes diferem', () => {
      expect(
        scopeOptionLabel({ id: 1, name: 'Suporte Técnico', agent: 'Joana v2' })
      ).toBe('Joana v2 · Suporte Técnico');
    });

    it('não quebra com valor nulo/indefinido', () => {
      expect(scopeOptionLabel(null)).toBe('');
      expect(scopeOptionLabel(undefined)).toBe('');
    });
  });

  describe('sourceScope', () => {
    const departments = [
      { id: 10, name: 'Maya v5.0', agent: 'Maya v5.0' },
      { id: 20, name: 'Suporte Técnico', agent: 'Joana v2' },
    ];

    it('classifica como compartilhado quando ai_department_id é nulo', () => {
      expect(sourceScope({ ai_department_id: null }, departments)).toEqual({
        status: 'shared',
      });
    });

    it('trata source nulo como compartilhado (sem quebrar)', () => {
      expect(sourceScope(null, departments)).toEqual({ status: 'shared' });
    });

    it('classifica como escopado e traz o label do agente quando o dept existe', () => {
      expect(sourceScope({ ai_department_id: 20 }, departments)).toEqual({
        status: 'scoped',
        label: 'Joana v2 · Suporte Técnico',
      });
    });

    it('classifica como órfão quando o dept não existe mais na lista', () => {
      expect(sourceScope({ ai_department_id: 999 }, departments)).toEqual({
        status: 'orphan',
      });
    });

    it('não confunde órfão (dept setado, some da lista) com compartilhado (nulo)', () => {
      const orphan = sourceScope({ ai_department_id: 999 }, departments);
      const shared = sourceScope({ ai_department_id: null }, departments);
      expect(orphan.status).toBe('orphan');
      expect(shared.status).toBe('shared');
      expect(orphan.status).not.toBe(shared.status);
    });
  });

  describe('buildScopeChips', () => {
    const departments = [
      { id: 10, name: 'Maya v5.0', agent: 'Maya v5.0' },
      { id: 20, name: 'Suporte Técnico', agent: 'Joana v2' },
    ];
    const labels = {
      all: 'Todos',
      shared: 'Compartilhado',
      orphan: 'Fonte órfã',
    };

    it('lista TODOS os agentes da conta, mesmo os sem nenhuma fonte (contagem 0)', () => {
      // Só o dept 10 tem fonte; o dept 20 (agente novo/vazio) precisa aparecer com count 0.
      const sources = [
        { ai_department_id: 10 },
        { ai_department_id: 10 },
        { ai_department_id: null },
      ];
      const chips = buildScopeChips(departments, sources, labels);
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
        { ai_department_id: 10 },
        { ai_department_id: 20 },
        { ai_department_id: 20 },
        { ai_department_id: null },
      ];
      const chips = buildScopeChips(departments, sources, labels);
      const by = v => chips.find(c => c.value === v);
      expect(by('all').count).toBe(4);
      expect(by('shared').count).toBe(1);
      expect(by('10').count).toBe(1);
      expect(by('20').count).toBe(2);
    });

    it('sempre começa por Todos e Compartilhado, nessa ordem', () => {
      const chips = buildScopeChips(departments, [], labels);
      expect(chips[0].value).toBe('all');
      expect(chips[1].value).toBe('shared');
    });

    it('mostra o chip Fonte órfã (com contagem) só quando há fonte apontando p/ dept inexistente', () => {
      const semOrfa = buildScopeChips(
        departments,
        [{ ai_department_id: 10 }],
        labels
      );
      expect(semOrfa.some(c => c.value === 'orphan')).toBe(false);

      const comOrfa = buildScopeChips(
        departments,
        [{ ai_department_id: 999 }, { ai_department_id: 999 }],
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
    const departments = [
      { id: 10, name: 'Maya v5.0', agent: 'Maya v5.0' },
      { id: 20, name: 'Suporte Técnico', agent: 'Joana v2' },
    ];
    const labels = {
      all: 'Todos',
      shared: 'Compartilhado',
      orphan: 'Fonte órfã',
    };

    it('devolve options do Select ({ value, label }) com a contagem embutida no label', () => {
      const sources = [
        { ai_department_id: 10 },
        { ai_department_id: 10 },
        { ai_department_id: null },
      ];
      const options = buildScopeOptions(departments, sources, labels);

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
        label: 'Joana v2 · Suporte Técnico (0)',
      });
    });

    it('preserva os values usados pela filtragem (all|shared|orphan|<deptId>)', () => {
      const options = buildScopeOptions(
        departments,
        [{ ai_department_id: 999 }],
        labels
      );
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
