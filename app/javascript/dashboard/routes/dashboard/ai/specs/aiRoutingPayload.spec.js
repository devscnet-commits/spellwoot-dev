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

// (2) buildInboxBindings manda SÓ mode. priority saiu da tela do agente (é decisão da caixa) — NÃO vai no
// payload por-agente, e o backend PRESERVA a priority no sync (não zera). Prova de mutação por nome.
describe('buildInboxBindings — só mode (priority não é da tela do agente)', () => {
  it('emite só { inbox_id, mode } — sem priority, mesmo em linha que atende', () => {
    const [b] = buildInboxBindings([
      { inbox_id: 1, mode: 'live', priority: 3 },
    ]);
    expect(b).toEqual({ inbox_id: 1, mode: 'live' });
    expect('priority' in b).toBe(false);
  });

  it('não emite priority nem em "Não atende"', () => {
    const [b] = buildInboxBindings([
      { inbox_id: 2, mode: 'none', priority: 9 },
    ]);
    expect(b).toEqual({ inbox_id: 2, mode: 'none' });
  });
});
