import { frontendURL } from '../../../helper/URLHelper';
import AiShadowRuns from './AiShadowRuns.vue';
import AiAgents from './AiAgents.vue';
import AiAgentDetail from './AiAgentDetail.vue';
import AiDepartments from './AiDepartments.vue';
import AiTools from './AiTools.vue';
import AiKnowledge from './AiKnowledge.vue';
import AiProfiles from './AiProfiles.vue';
import AiCosts from './AiCosts.vue';

// Minimal, read-only validation surface for the AI Core shadow runs (F1 vertical slice).
// Not the definitive "Agentes IA" UI — just enough to validate the shadow before going live.
export const routes = [
  {
    path: frontendURL('accounts/:accountId/ai/shadow-runs'),
    name: 'ai_shadow_runs',
    component: AiShadowRuns,
    meta: {
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/ai/agents'),
    name: 'ai_agents_index',
    component: AiAgents,
    meta: {
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/ai/agents/:agentId'),
    name: 'ai_agent_detail',
    component: AiAgentDetail,
    meta: {
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/ai/agents/:agentId/departments'),
    name: 'ai_departments_index',
    component: AiDepartments,
    meta: {
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/ai/agents/:agentId/departments/:departmentId/tools'),
    name: 'ai_tools_index',
    component: AiTools,
    meta: {
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/ai/agents/:agentId/departments/:departmentId/knowledge'),
    name: 'ai_knowledge_index',
    component: AiKnowledge,
    meta: {
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/ai/profiles'),
    name: 'ai_profiles_index',
    component: AiProfiles,
    meta: {
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/ai/costs'),
    name: 'ai_costs_index',
    component: AiCosts,
    meta: {
      permissions: ['administrator'],
    },
  },
];
