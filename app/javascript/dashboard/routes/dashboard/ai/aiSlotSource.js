// União das fontes de chave de slot da etapa, com a ORIGEM marcada — porque a origem decide se o dado
// coletado aparece no painel da conversa:
//   - LeadVariable (Ai::LeadVariable): variável INTERNA, memória de trabalho da IA (ai_collected_facts).
//     NÃO aparece na lateral da conversa.
//   - CustomAttributeDefinition (conversation_attribute): dado EXPORTADO — o valor coletado espelha em
//     conversation.custom_attributes e aparece no painel (o espelhamento opt-in que já existe).
//
// Uma chave que existe nas DUAS fontes (alguém criou de propósito um CAD com o mesmo nome da variável)
// aparece UMA vez marcada como 'panel': o dado espelha, então é o fato relevante. `source: 'panel'` vence.
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
    .filter(a => a?.attribute_model === 'conversation_attribute')
    .forEach(a => {
      const key = (a?.attribute_key || '').toString().trim();
      if (key) map.set(key, 'panel'); // CAD existe => aparece no painel (sobrepõe 'internal')
    });

  return [...map.entries()].map(([value, source]) => ({ value, source }));
};
