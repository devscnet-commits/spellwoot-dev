import { frontendURL } from '../../../../helper/URLHelper';

import SettingsWrapper from '../SettingsWrapper.vue';
import Index from './Index.vue';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/message-templates'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'message_templates_wrapper',
          meta: {
            permissions: ['administrator'],
          },
          redirect: to => {
            return { name: 'message_templates_list', params: to.params };
          },
        },
        {
          path: 'list',
          name: 'message_templates_list',
          meta: {
            permissions: ['administrator'],
          },
          component: Index,
        },
      ],
    },
  ],
};
