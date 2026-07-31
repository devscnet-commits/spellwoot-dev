import {
  humanizeFactKey,
  displayFactValue,
  collectedFactsList,
} from '../aiCollectedFacts';

// Exibição READ-ONLY dos ai_collected_facts: humanização leve da chave (sem tabela por chave), token de
// ausência -> "não informado", ordem de COLETA (não alfabética). Prova de mutação por nome.
describe('humanizeFactKey — underscore vira espaço + primeira maiúscula', () => {
  it('email_cliente -> "Email cliente"', () => {
    expect(humanizeFactKey('email_cliente')).toBe('Email cliente');
  });

  it('chave de UMA palavra só capitaliza', () => {
    expect(humanizeFactKey('cidade')).toBe('Cidade');
  });

  it('não traduz por chave (sem hardcode de tenant): telefone_secundario -> "Telefone secundario"', () => {
    expect(humanizeFactKey('telefone_secundario')).toBe('Telefone secundario');
  });
});

describe('displayFactValue — token de ausência vira "não informado"', () => {
  it('__sem_valor__ -> "não informado" (mesmo que o resumo de handoff)', () => {
    expect(displayFactValue('__sem_valor__')).toBe('não informado');
  });

  it('valor real passa cru', () => {
    expect(displayFactValue('joao@x.com')).toBe('joao@x.com');
  });
});

describe('collectedFactsList — ordem de COLETA, label + valor mapeados', () => {
  it('preserva a ORDEM de inserção das chaves (não alfabética)', () => {
    const facts = {
      telefone: '49...',
      email_cliente: 'a@b.com',
      cidade: 'Maravilha',
    };
    expect(collectedFactsList(facts).map(f => f.key)).toEqual([
      'telefone',
      'email_cliente',
      'cidade',
    ]);
  });

  it('mapeia label (humanizado) e value (token -> não informado)', () => {
    const facts = { email_cliente: 'a@b.com', complemento: '__sem_valor__' };
    expect(collectedFactsList(facts)).toEqual([
      { key: 'email_cliente', label: 'Email cliente', value: 'a@b.com' },
      { key: 'complemento', label: 'Complemento', value: 'não informado' },
    ]);
  });

  it('hash vazio/nulo -> []', () => {
    expect(collectedFactsList({})).toEqual([]);
    expect(collectedFactsList(null)).toEqual([]);
  });
});
