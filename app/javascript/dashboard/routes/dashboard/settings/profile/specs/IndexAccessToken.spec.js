import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import ProfileSettings from '../Index.vue';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    isEditorHotKeyEnabled: vi.fn(),
    updateUISettings: vi.fn(),
  }),
}));
vi.mock('dashboard/composables/useFontSize', () => ({
  useFontSize: () => ({ currentFontSize: 'default', updateFontSize: vi.fn() }),
}));
vi.mock('shared/composables/useBranding', () => ({
  useBranding: () => ({ replaceInstallationName: text => text }),
}));

// Módulo "Token de acesso pessoal (API)" do plano: sem ele a seção do token some do perfil.
const hasTokenSection = wrapper =>
  wrapper
    .findAllComponents({ name: 'SectionLayout' })
    .some(s => s.props('title') === 'PROFILE_SETTINGS.FORM.ACCESS_TOKEN.TITLE');

const mountProfile = account => {
  const store = createStore({
    getters: {
      getCurrentUser: () => ({ id: 1, access_token: 'tok-123' }),
      getCurrentUserID: () => 1,
      'globalConfig/get': () => ({}),
      getCurrentAccountId: () => 2,
      'accounts/getAccount': () => id => (id === 2 ? account : undefined),
    },
  });
  return shallowMount(ProfileSettings, {
    global: { plugins: [store], mocks: { $t: key => key } },
  });
};

describe('Perfil — Token de acesso pelo plano', () => {
  it('mostra o token quando o plano libera', () => {
    const wrapper = mountProfile({ id: 2, api_user_token_allowed: true });

    expect(hasTokenSection(wrapper)).toBe(true);
  });

  it('esconde o token quando o plano não libera', () => {
    const wrapper = mountProfile({ id: 2, api_user_token_allowed: false });

    expect(hasTokenSection(wrapper)).toBe(false);
  });

  it('esconde enquanto a conta não carregou', () => {
    const wrapper = mountProfile(undefined);

    expect(hasTokenSection(wrapper)).toBe(false);
  });
});
