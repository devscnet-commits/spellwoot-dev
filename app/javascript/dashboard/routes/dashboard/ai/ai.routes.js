import { frontendURL } from '../../../helper/URLHelper';
import AiShadowRuns from './AiShadowRuns.vue';

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
];
