// União das fontes de chave de slot da etapa, com a ORIGEM marcada — porque a origem decide se o dado
// coletado aparece no painel da conversa:
//   - LeadVariable (Ai::LeadVariable): variável INTERNA, memória de trabalho da IA (ai_collected_facts).
//     NÃO aparece na lateral da conversa.
//   - CustomAttributeDefinition (conversation_attribute OU contact_attribute): dado EXPORTADO — o valor
//     coletado espelha em conversation.custom_attributes OU contact.custom_attributes (Ai::StateManager
//     roteia pelo attribute_model da própria definição) e aparece no painel — os DOIS tipos, não só
//     conversation_attribute (achado do usuário: um CAD de contato nunca aparecia pro atendente humano,
//     porque nem entrava como opção aqui pra começo de conversa).
//
// Uma chave que existe em mais de uma fonte (alguém criou de propósito um CAD com o mesmo nome da
// variável, ou um CAD cadastrado nos dois attribute_model) aparece UMA vez marcada como 'panel': o
// dado espelha, então é o fato relevante. `source: 'panel'` vence sobre 'internal'.
export const buildSlotKeyOptions = (
  leadVariables = [],
  customAttributes = []
) => {
  const map = new Map(); // key -> 'internal' | 'panel'

  leadVariables.forEach(v => {
    const key = (v?.name || '').toString().trim();
    if (key && !map.has(key)) map.set(key, 'internal');
  });

  customAttributes
    .filter(
      a =>
        a?.attribute_model === 'conversation_attribute' ||
        a?.attribute_model === 'contact_attribute'
    )
    .forEach(a => {
      const key = (a?.attribute_key || '').toString().trim();
      if (key) map.set(key, 'panel'); // CAD existe => aparece no painel (sobrepõe 'internal')
    });

  return [...map.entries()].map(([value, source]) => ({ value, source }));
};
