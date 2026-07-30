import {
  defaultAgentForm,
  buildAgentPayload,
  buildInboxBindings,
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
