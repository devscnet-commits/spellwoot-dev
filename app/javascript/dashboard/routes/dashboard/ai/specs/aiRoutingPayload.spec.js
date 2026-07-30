import {
  defaultAgentForm,
  buildAgentPayload,
  buildInboxBindings,
  nextLivePriority,
  resequenceLivePriorities,
} from '../aiRoutingPayload';

// (1) O "Time deste agente" (team_id) NÃO é mais emitido. O spec prova que a CHAVE está AUSENTE — não que
// o valor é vazio. Se alguém readicionar team_id ao form, o PATCH volta a tocar a coluna (zerando o
// override quando vazio). Issue H1.
describe('agentForm — team_id ausente do form e do payload', () => {
  it('o form default não tem a chave team_id', () => {
    expect('team_id' in defaultAgentForm()).toBe(false);
  });

  it('o payload do save não emite team_id (chave ausente, não valor vazio)', () => {
    const payload = buildAgentPayload(defaultAgentForm());
    expect('team_id' in payload).toBe(false);
  });

  it('preserva os demais campos e normaliza o name a partir do assistant_name', () => {
    const payload = buildAgentPayload({
      ...defaultAgentForm(),
      name: '',
      assistant_name: 'Aria',
      handoff_team_ids: [7],
    });
    expect(payload.name).toBe('Aria');
    expect(payload.handoff_team_ids).toEqual([7]);
  });
});

// (2) priority da caixa: presente quando ATENDE, AUSENTE quando "Não atende".
describe('buildInboxBindings — priority por linha', () => {
  it('inclui priority na linha que atende (mode live)', () => {
    const [b] = buildInboxBindings([
      { inbox_id: 1, mode: 'live', priority: 3 },
    ]);
    expect(b).toEqual({ inbox_id: 1, mode: 'live', priority: 3 });
  });

  it('OMITE a chave priority quando a linha está em "Não atende" (mode none)', () => {
    const [b] = buildInboxBindings([
      { inbox_id: 2, mode: 'none', priority: 9 },
    ]);
    expect('priority' in b).toBe(false);
    expect(b).toEqual({ inbox_id: 2, mode: 'none' });
  });

  it('round-trip: o priority devolvido pelo show sobrevive de volta ao payload', () => {
    // shape do show: { inbox_id, name, mode, priority }
    const fromServer = [
      { inbox_id: 5, name: 'Suporte', mode: 'live', priority: 2 },
    ];
    const [b] = buildInboxBindings(fromServer);
    expect(b.priority).toBe(2);
  });
});

// (3) Prioridade AUTOMÁTICA por ordem de marcação: marcar => próximo da sequência; desmarcar => renumera.
describe('nextLivePriority — próximo número ao marcar "Atende"', () => {
  it('primeira caixa marcada recebe 1 (nenhuma outra em Atende)', () => {
    const inboxes = [{ inbox_id: 1, mode: 'live', priority: 0 }];
    expect(nextLivePriority(inboxes, inboxes[0])).toBe(1);
  });

  it('a segunda recebe 2 (max das outras em Atende + 1)', () => {
    const a = { inbox_id: 1, mode: 'live', priority: 1 };
    const b = { inbox_id: 2, mode: 'live', priority: 0 };
    expect(nextLivePriority([a, b], b)).toBe(2);
  });

  it('ignora as caixas que NÃO atendem e a própria caixa', () => {
    const a = { inbox_id: 1, mode: 'live', priority: 3 };
    const off = { inbox_id: 2, mode: 'none', priority: 9 };
    const target = { inbox_id: 3, mode: 'live', priority: 0 };
    expect(nextLivePriority([a, off, target], target)).toBe(4); // max(3) + 1; o 9 de "none" é ignorado
  });
});

describe('resequenceLivePriorities — renumera ao desmarcar (fecha o buraco, preserva a ordem)', () => {
  it('compacta 1..N e ignora as que não atendem', () => {
    const a = { inbox_id: 1, mode: 'live', priority: 1 };
    const gone = { inbox_id: 2, mode: 'none', priority: 2 }; // acabou de sair
    const c = { inbox_id: 3, mode: 'live', priority: 3 };
    resequenceLivePriorities([a, gone, c]);
    expect(a.priority).toBe(1);
    expect(c.priority).toBe(2); // era 3 -> compacta para 2 (buraco fechado)
    expect(gone.priority).toBe(2); // "none" não é tocada
  });

  it('preserva a ordem relativa da edição manual (não a magnitude)', () => {
    // usuário empurrou B para o fim (priority 10); ao renumerar, a ordem A < C < B é preservada
    const a = { inbox_id: 1, mode: 'live', priority: 1 };
    const b = { inbox_id: 2, mode: 'live', priority: 10 };
    const c = { inbox_id: 3, mode: 'live', priority: 3 };
    resequenceLivePriorities([a, b, c]);
    expect([a.priority, c.priority, b.priority]).toEqual([1, 2, 3]);
  });
});
