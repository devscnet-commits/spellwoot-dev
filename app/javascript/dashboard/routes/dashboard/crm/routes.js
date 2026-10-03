import { frontendURL } from '../../../helper/URLHelper';
import { FEATURE_FLAGS } from '../../../featureFlags';
import PipelineBoardPage from './pages/PipelineBoardPage.vue';
import PipelineAutomationsPage from './pages/PipelineAutomationsPage.vue';
import PipelineAiFollowupsPage from './pages/PipelineAiFollowupsPage.vue';
import PipelineReportsPage from './pages/PipelineReportsPage.vue';

// CRM: the sales pipelines (closing flows with stages) as a kanban, their stage automations and AI
// follow-up cadences, and the pipeline reports.
export const routes = [
  {
    path: frontendURL('accounts/:accountId/crm/kanban'),
    name: 'crm_pipeline_index',
    component: PipelineBoardPage,
    meta: {
      featureFlag: FEATURE_FLAGS.CRM_KANBAN,
      permissions: ['administrator', 'agent'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/crm/automations'),
    name: 'crm_automations_index',
    component: PipelineAutomationsPage,
    meta: {
      featureFlag: FEATURE_FLAGS.CRM_AUTOMATIONS,
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/crm/ai-followups'),
    name: 'crm_ai_followups_index',
    component: PipelineAiFollowupsPage,
    meta: {
      featureFlag: FEATURE_FLAGS.CRM_AUTOMATIONS,
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/crm/reports'),
    name: 'crm_pipeline_reports',
    component: PipelineReportsPage,
    meta: {
      featureFlag: FEATURE_FLAGS.CRM_KANBAN,
      permissions: ['administrator', 'report_manage'],
    },
  },
];
