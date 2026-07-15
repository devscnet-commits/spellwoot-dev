import { scopeOptionLabel, sourceScope } from '../knowledgeScope';

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
});
