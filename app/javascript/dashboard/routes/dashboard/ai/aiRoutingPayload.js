// Payloads da aba "Atendimentos e transferências" (AiAgentDetail), extraídos em funções PURAS para
// testar sem montar o componente monolítico — mesmo padrão do aiStepPayload.js.
//
// Duas garantias que este módulo tranca (prova de mutação por nome no spec):
//   1. team_id NÃO existe no form do agente. Ele grava o override que sobrepõe whitelist/intenção/fallback
//      (issue H1). Saiu da UI; o dado permanece no banco porque a CHAVE fica AUSENTE do payload — não vira
//      '' (que zeraria a coluna no PATCH). Por isso o default abaixo não tem a chave.
//   2. priority da caixa só vai no payload quando a linha ATENDE (mode != none). "Não atende" destrói o
//      binding no backend, então mandar priority ali seria ruído.

// Fábrica (não constante compartilhada): cada instância recebe arrays frescos.
export const defaultAgentForm = () => ({
  name: '',
  assistant_name: '',
  company_name: '',
  site: '',
  identify_as: 'human',
  assistant_avatar: '',
  ai_operation_profile_id: '',
  // team_id: PROPOSITALMENTE AUSENTE (ver nota 1 no topo).
  handoff_team_ids: [],
  handoff_agent_ids: [],
  fallback_handoff_team_id: '',
  assistant_personality: '',
  assistant_language: 'pt-BR',
  base_prompt: '',
  guardrails: '',
  stage: 'experimental',
  status: 'active',
});

// form -> payload do PATCH/POST do agente: spread-e-sobrescreve (preserva campos futuros), só normaliza o
// name. Como o form não tem team_id, o payload também não tem — o backend não toca a coluna.
export const buildAgentPayload = form => ({
  ...form,
  name: form.name || form.assistant_name,
});

// caixas -> bindings do PUT (só mode). priority NÃO vai por aqui: é decisão POR CAIXA entre agentes,
// editada na tela da caixa (BotConfiguration). O backend PRESERVA a priority no sync (não zera).
export const buildInboxBindings = inboxes =>
  inboxes.map(i => ({ inbox_id: i.inbox_id, mode: i.mode }));
