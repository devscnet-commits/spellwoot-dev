// Empate de prioridade na caixa — espelha o Ai::GatewayRunJob#emit_priority_tie (nível config): entre as
// IAs que RESPONDEM (mode 'live') na MESMA caixa, >=2 dividindo o MENOR priority. Só o menor importa: é ele
// que a eleição ([priority ASC, id ASC]) usa; empate ali cai no desempate por id. Devolve { priority, names }
// ou null. (Sombra não compete -> não entra.)
export const priorityTie = agents => {
  const live = (agents || []).filter(a => a && a.mode === 'live');
  if (live.length < 2) return null;
  const min = Math.min(...live.map(a => Number(a.priority) || 0));
  const tied = live.filter(a => (Number(a.priority) || 0) === min);
  return tied.length >= 2
    ? { priority: min, names: tied.map(a => a.agent_name) }
    : null;
};

// Payload do PATCH: só os agentes que respondem (live) — priority de sombra é irrelevante para a eleição.
export const buildPriorityPayload = agents =>
  (agents || [])
    .filter(a => a && a.mode === 'live')
    .map(a => ({ agent_id: a.agent_id, priority: Number(a.priority) || 1 }));
