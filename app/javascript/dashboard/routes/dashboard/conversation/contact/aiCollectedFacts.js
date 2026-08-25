// Dados coletados NESTA conversa (conversation.additional_attributes.ai_collected_facts) para exibição
// READ-ONLY na "Memória da IA". Read-only é a decisão central: campo editável na lateral deixaria o
// atendente alterar no meio da conversa sem o motor (ai_collected_facts) saber.

// Espelho do backend Ai::StepSlot (ABSENT / ABSENT_LABEL). Slot opcional declinado grava o token; o resumo
// de handoff já o mostra como "não informado" — aqui fazemos o mesmo, sem duplicar tabela por chave.
const ABSENT_TOKEN = '__sem_valor__';
const ABSENT_LABEL = 'não informado';

// Humanização LEVE da chave (do tenant): underscore vira espaço + primeira maiúscula. SEM tabela de
// tradução por chave — a chave é do tenant e uma tabela viraria hardcode (ex.: 'email_cliente' -> 'Email
// cliente'). Só apresentação.
export const humanizeFactKey = key =>
  String(key ?? '')
    .replace(/_/g, ' ')
    .replace(/^./, char => char.toUpperCase());

// Token de ausência -> "não informado"; qualquer outro valor passa cru.
export const displayFactValue = value =>
  String(value) === ABSENT_TOKEN ? ABSENT_LABEL : value;

// facts (hash) -> [{ key, label, value }] na ORDEM DE COLETA (ordem de inserção das chaves no hash, que
// Object.entries preserva para chaves string), NÃO alfabética — reflete o caminho da conversa.
export const collectedFactsList = facts =>
  Object.entries(facts || {}).map(([key, value]) => ({
    key,
    label: humanizeFactKey(key),
    value: displayFactValue(value),
  }));
