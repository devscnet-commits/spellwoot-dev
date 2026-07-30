import { priorityTie, buildPriorityPayload } from '../aiInboxPriority';

// Empate = >=2 IAs No ar (live) dividindo o MENOR priority na caixa — o agent.priority_tie que o backend
// emite. Só o menor importa (é o que a eleição usa). Prova de mutação por nome.
describe('priorityTie — empate real na caixa', () => {
  it('null quando há menos de 2 IAs No ar', () => {
    expect(priorityTie([{ agent_name: 'A', mode: 'live', priority: 1 }])).toBe(
      null
    );
  });

  it('avisa quando 2+ live dividem o MENOR priority, com os nomes', () => {
    const tie = priorityTie([
      { agent_name: 'Maya', mode: 'live', priority: 1 },
      { agent_name: 'Cris', mode: 'live', priority: 1 },
      { agent_name: 'Bot3', mode: 'live', priority: 2 },
    ]);
    expect(tie).toEqual({ priority: 1, names: ['Maya', 'Cris'] });
  });

  it('null quando os menores são distintos (sem empate no menor)', () => {
    expect(
      priorityTie([
        { agent_name: 'A', mode: 'live', priority: 1 },
        { agent_name: 'B', mode: 'live', priority: 2 },
      ])
    ).toBe(null);
  });

  it('ignora as IAs em SOMBRA (não competem na eleição)', () => {
    // duas em priority 1, mas uma é shadow -> só 1 live no menor -> sem empate
    expect(
      priorityTie([
        { agent_name: 'A', mode: 'live', priority: 1 },
        { agent_name: 'B', mode: 'shadow', priority: 1 },
      ])
    ).toBe(null);
  });

  it('empate no menor mesmo com outra dupla empatada acima (só o menor conta)', () => {
    const tie = priorityTie([
      { agent_name: 'A', mode: 'live', priority: 2 },
      { agent_name: 'B', mode: 'live', priority: 2 },
      { agent_name: 'C', mode: 'live', priority: 5 },
      { agent_name: 'D', mode: 'live', priority: 5 },
    ]);
    expect(tie).toEqual({ priority: 2, names: ['A', 'B'] });
  });
});

describe('buildPriorityPayload — só os agentes que respondem (live)', () => {
  it('manda { agent_id, priority } só dos live; ignora sombra', () => {
    const payload = buildPriorityPayload([
      { agent_id: 1, mode: 'live', priority: 2 },
      { agent_id: 2, mode: 'shadow', priority: 9 },
    ]);
    expect(payload).toEqual([{ agent_id: 1, priority: 2 }]);
  });

  it('prioridade inválida/vazia cai no default 1', () => {
    const payload = buildPriorityPayload([
      { agent_id: 3, mode: 'live', priority: null },
    ]);
    expect(payload).toEqual([{ agent_id: 3, priority: 1 }]);
  });
});
