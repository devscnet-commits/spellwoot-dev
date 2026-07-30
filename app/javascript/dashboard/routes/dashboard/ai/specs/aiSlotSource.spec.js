import { buildSlotKeyOptions } from '../aiSlotSource';

// A origem decide se o dado coletado aparece no painel da conversa: LeadVariable = interna (memória da IA);
// CustomAttributeDefinition conversation_attribute = painel (espelha). Prova de mutação por nome.
describe('buildSlotKeyOptions — união com origem marcada', () => {
  it('LeadVariable vira source: internal', () => {
    expect(buildSlotKeyOptions([{ name: 'periodo_reservado' }], [])).toEqual([
      { value: 'periodo_reservado', source: 'internal' },
    ]);
  });

  it('CAD conversation_attribute vira source: panel; outros modelos são ignorados', () => {
    const opts = buildSlotKeyOptions(
      [],
      [
        { attribute_model: 'conversation_attribute', attribute_key: 'cidade' },
        { attribute_model: 'contact_attribute', attribute_key: 'telefone' },
      ]
    );
    expect(opts).toEqual([{ value: 'cidade', source: 'panel' }]);
  });

  it('chave nas DUAS fontes aparece UMA vez como panel (o dado espelha, é o fato relevante)', () => {
    const opts = buildSlotKeyOptions(
      [{ name: 'cidade' }],
      [{ attribute_model: 'conversation_attribute', attribute_key: 'cidade' }]
    );
    expect(opts).toEqual([{ value: 'cidade', source: 'panel' }]);
  });

  it('ignora nomes/chaves vazios e faz trim', () => {
    const opts = buildSlotKeyOptions(
      [{ name: '  ' }, { name: ' bairro ' }],
      [{ attribute_model: 'conversation_attribute', attribute_key: '' }]
    );
    expect(opts).toEqual([{ value: 'bairro', source: 'internal' }]);
  });

  it('união de fontes distintas preserva as duas', () => {
    const opts = buildSlotKeyOptions(
      [{ name: 'interno_a' }],
      [{ attribute_model: 'conversation_attribute', attribute_key: 'painel_b' }]
    );
    expect(opts).toContainEqual({ value: 'interno_a', source: 'internal' });
    expect(opts).toContainEqual({ value: 'painel_b', source: 'panel' });
  });
});
