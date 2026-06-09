import { frontendURL } from '../../../../helper/URLHelper';
import SettingsWrapper from '../SettingsWrapper.vue';
import SettingsContent from '../Wrapper.vue';
import OperationalFlowsIndex from './Index.vue';
import FlowEditPage from './FlowEditPage.vue';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/operational-flows'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          redirect: to => {
            return {
              name: 'settings_operational_flows_list',
              params: to.params,
            };
          },
        },
        {
          path: 'list',
          name: 'settings_operational_flows_list',
          component: OperationalFlowsIndex,
          meta: {
            permissions: ['administrator'],
          },
        },
      ],
    },
    {
      path: frontendURL('accounts/:accountId/settings/operational-flows'),
      component: SettingsContent,
      props: () => {
        return {
          headerTitle: 'OPERATIONAL_FLOWS_SETTINGS.HEADER',
          icon: 'i-lucide-route',
          showBackButton: true,
        };
      },
      children: [
        {
          path: 'new',
          name: 'settings_operational_flows_new',
          component: FlowEditPage,
          meta: {
            permissions: ['administrator'],
          },
        },
        {
          path: ':flowId/edit',
          name: 'settings_operational_flows_edit',
          component: FlowEditPage,
          meta: {
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
