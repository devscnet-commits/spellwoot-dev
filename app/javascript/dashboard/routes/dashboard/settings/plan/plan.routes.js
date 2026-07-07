import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';
import { frontendURL } from '../../../../helper/URLHelper';

import SettingsWrapper from '../SettingsWrapper.vue';
import Index from './Index.vue';

const meta = {
  featureFlag: null, // Not gated by feature flag for now (internal page)
  permissions: ['administrator'],
  installationTypes: [INSTALLATION_TYPES.CLOUD, INSTALLATION_TYPES.ENTERPRISE],
};

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/plan'),
      component: SettingsWrapper,
      props: {},
      children: [
        {
          path: '',
          name: 'plan_wrapper',
          meta,
          redirect: to => {
            return { name: 'plan_settings_list', params: to.params };
          },
        },
        {
          path: 'list',
          name: 'plan_settings_list',
          meta,
          component: Index,
        },
      ],
    },
  ],
};
