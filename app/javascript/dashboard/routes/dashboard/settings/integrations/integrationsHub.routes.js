import { frontendURL } from '../../../../helper/URLHelper';
import SettingsWrapper from '../SettingsWrapper.vue';
import IntegrationsHubIndex from './IntegrationsHub.vue';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/integrations-hub'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'integrations_hub',
          component: IntegrationsHubIndex,
          meta: {
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
