import { frontendURL } from '../../../helper/URLHelper';
import AiShadowRuns from './AiShadowRuns.vue';
import AiShadows from './AiShadows.vue';
import AiAgents from './AiAgents.vue';
import AiAgentDetail from './AiAgentDetail.vue';
import AiProfiles from './AiProfiles.vue';
import AiKnowledge from './AiKnowledge.vue';
import AiCosts from './AiCosts.vue';

// "Agentes IA" configuration surface. Each agent is edited on its own detail page (tabs);
// Tools/Knowledge/Steps are embedded as tabs inside that same page.
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
    path: frontendURL('accounts/:accountId/ai/shadows'),
    name: 'ai_shadows_index',
    component: AiShadows,
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
    path: frontendURL('accounts/:accountId/ai/profiles'),
    name: 'ai_profiles_index',
    component: AiProfiles,
    meta: {
      permissions: ['administrator'],
    },
  },
  {
    path: frontendURL('accounts/:accountId/ai/knowledge'),
    name: 'ai_knowledge_index',
    component: AiKnowledge,
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
