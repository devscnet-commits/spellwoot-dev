// Prioridade de eleição da caixa via rádio "IA principal" — empate deixa de existir por construção: uma IA
// é principal (priority 1), as demais que respondem ficam em 2 (a eleição `min_by [priority, id]` só usa o
// menor; a ordem dos não-principais nunca é lida). Sombra não compete -> fora do grupo.

// Deriva a IA principal do estado ATUAL (para o render inicial, SEM mutar): a live de menor [priority, id]
// — o MESMO que a eleição escolhe. Legado empatado ([1,1]) pré-seleciona a de menor id; a normalização para
// [1,2] só acontece no SAVE (ação explícita), nunca no load.
export const principalAgentId = agents => {
  const live = (agents || []).filter(a => a && a.mode === 'live');
  if (!live.length) return null;

  return live
    .slice()
    .sort(
      (a, b) =>
        (Number(a.priority) || 0) - (Number(b.priority) || 0) ||
        a.agent_id - b.agent_id
    )[0].agent_id;
};

// Payload do PATCH: só as IAs que respondem (live). A principal recebe 1, as demais 2 (sombra não vai —
// priority de sombra é irrelevante). O backend não muda.
export const buildPriorityPayload = (agents, principalId) =>
  (agents || [])
    .filter(a => a && a.mode === 'live')
    .map(a => ({
      agent_id: a.agent_id,
      priority: a.agent_id === principalId ? 1 : 2,
    }));
