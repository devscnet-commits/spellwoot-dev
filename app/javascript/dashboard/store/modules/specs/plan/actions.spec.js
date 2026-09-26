import { actions } from '../../plan';
import AccountPlanAPI from '../../../../api/account/plan';

vi.mock('../../../../api/account/plan', () => ({
  default: { getLimits: vi.fn(), upgrade: vi.fn() },
}));

const commit = vi.fn();

describe('plan #fetchPlanData', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('guarda os dados do plano quando a conta tem assinatura', async () => {
    const data = { plan: { name: 'PLUS' }, limits: [] };
    AccountPlanAPI.getLimits.mockResolvedValue({ data });

    await actions.fetchPlanData({ commit });

    expect(commit.mock.calls).toEqual([
      ['SET_UI_FETCHING', true],
      ['SET_FETCH_ERROR', null],
      ['SET_PLAN_DATA', data],
      ['SET_UI_FETCHING', false],
    ]);
  });

  it('marca "no_plan" quando a API responde 404 (conta sem assinatura)', async () => {
    AccountPlanAPI.getLimits.mockRejectedValue({ response: { status: 404 } });

    await actions.fetchPlanData({ commit });

    expect(commit).toHaveBeenCalledWith('SET_FETCH_ERROR', 'no_plan');
    expect(commit).not.toHaveBeenCalledWith('SET_PLAN_DATA', expect.anything());
  });

  it('marca "unknown" para qualquer outra falha', async () => {
    AccountPlanAPI.getLimits.mockRejectedValue({ response: { status: 500 } });

    await actions.fetchPlanData({ commit });

    expect(commit).toHaveBeenCalledWith('SET_FETCH_ERROR', 'unknown');
  });
});
