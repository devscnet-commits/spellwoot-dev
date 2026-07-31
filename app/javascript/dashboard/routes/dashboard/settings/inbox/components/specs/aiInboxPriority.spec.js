import { principalAgentId, buildPriorityPayload } from '../aiInboxPriority';

// Rádio "IA principal": a principal deriva do menor [priority, id] entre as live (igual à eleição do
// backend). buildPriorityPayload grava 1 na principal e 2 nas demais live. Prova de mutação por nome.
describe('principalAgentId — deriva a IA principal do estado atual (sem mutar)', () => {
  it('menor priority entre as live vence', () => {
    const agents = [
      { agent_id: 1, mode: 'live', priority: 2 },
      { agent_id: 2, mode: 'live', priority: 1 },
    ];
    expect(principalAgentId(agents)).toBe(2);
  });

  it('empate no priority -> desempate pelo MENOR agent_id (igual ao min_by [priority, id])', () => {
    const agents = [
      { agent_id: 5, mode: 'live', priority: 1 },
      { agent_id: 3, mode: 'live', priority: 1 }, // mesmo priority, id menor
    ];
    expect(principalAgentId(agents)).toBe(3);
  });

  it('ignora as IAs em sombra (não competem)', () => {
    const agents = [
      { agent_id: 1, mode: 'shadow', priority: 1 },
      { agent_id: 2, mode: 'live', priority: 5 },
    ];
    expect(principalAgentId(agents)).toBe(2);
  });

  it('sem nenhuma live -> null', () => {
    expect(
      principalAgentId([{ agent_id: 1, mode: 'shadow', priority: 1 }])
    ).toBe(null);
    expect(principalAgentId([])).toBe(null);
  });
});

describe('buildPriorityPayload — principal 1, demais live 2 (sombra fora)', () => {
  it('grava 1 na principal e 2 nas outras live', () => {
    const agents = [
      { agent_id: 1, mode: 'live', priority: 9 },
      { agent_id: 2, mode: 'live', priority: 9 },
      { agent_id: 3, mode: 'live', priority: 9 },
    ];
    expect(buildPriorityPayload(agents, 2)).toEqual([
      { agent_id: 1, priority: 2 },
      { agent_id: 2, priority: 1 },
      { agent_id: 3, priority: 2 },
    ]);
  });

  it('cura o legado empatado ([1,1] -> [1,2]) quando a principal é a de menor id', () => {
    const agents = [
      { agent_id: 3, mode: 'live', priority: 1 },
      { agent_id: 7, mode: 'live', priority: 1 },
    ];
    const principal = principalAgentId(agents); // 3 (menor id no empate)
    expect(buildPriorityPayload(agents, principal)).toEqual([
      { agent_id: 3, priority: 1 },
      { agent_id: 7, priority: 2 },
    ]);
  });

  it('sombra NÃO entra no payload (priority irrelevante)', () => {
    const agents = [
      { agent_id: 1, mode: 'live', priority: 1 },
      { agent_id: 2, mode: 'shadow', priority: 1 },
    ];
    expect(buildPriorityPayload(agents, 1)).toEqual([
      { agent_id: 1, priority: 1 },
    ]);
  });
});
