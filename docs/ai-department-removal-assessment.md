# Assessment: removing `Ai::Department` (2026-08-17)

Scoping research only — no code changed. Written so this can be picked back up in a
later session without re-deriving it. Trigger for the question: the business only ever
configures **one department per `Ai::Agent`** in practice, and the extra layer was
causing confusion (config needing to be set/found in multiple places for what is
conceptually a single bot).

## Correction to watch for
The original ask assumed a Python orchestrator boundary (`api/internal/ai_execute_tool_controller.rb`,
a payload crossing to a Python service). **That controller and the Python service exist
in this codebase** (added in the OpenAI Responses API migration, see
`app/services/ai/python_orchestrator_client.rb` and `ai-orchestrator/`) — the research
agent that produced most of this doc ran against a snapshot that predates that migration
and said they don't exist. Re-verify the Python payload/serialization boundary
specifically before starting implementation; everything else below still applies.

## 1. Models with `ai_department_id` / Department associations
Table `ai_departments` (owned by `ai_agent_id`), plus these dependents:
- `Ai::Playbook` — `belongs_to :department` **required** (`ai_department_id` NOT NULL)
- `Ai::LeadVariable` — `belongs_to :department` **required**
- `Ai::DepartmentIntegration` — join table, department **required**
- `Ai::DepartmentInbox` — join table, department **required** (routing)
- `Ai::Tool` — `belongs_to :department, optional: true` (already nullable)
- `Ai::KnowledgeSource` — `belongs_to :department, optional: true` (already nullable)
- `Ai::Run` — `ai_department_id` nullable, added later purely as a metrics dimension
- `Ai::Agent` has `has_many :departments`; `Ai::PlaybookVersion` carries `ai_department_id` too.

## 2. Where Department is resolved/passed
- `Ai::DepartmentResolver.resolve` — the multi-department classifier, called from
  `Ai::Gateway` (every inbound message), `Ai::Copilot` (every suggestion), `Ai::Tester`
  (Test tab), and `Ai::FollowupConversationJob#resolved_department` (fallback path only,
  when no prior `Ai::Run` exists for the conversation).
- `Ai::Gateway#run` — threads a `department` object through `Ai::ReplyPolicy`,
  `Ai::PromptCompiler`/`Ai::PythonOrchestratorClient`, `Ai::HandoffEvaluator`,
  `department.tools`, `department.playbook`, `department.lead_variables`.
- `Ai::ReplyPolicy`, `Ai::HandoffEvaluator`, `Ai::PromptCompiler` all take `department:`
  as a required keyword arg and read its jsonb (`behavior`, `transfer_rules`, `close_rules`).
- `Ai::MessageGrouping.delay_seconds`, `followup_sweep_job.rb`, `sla_sweep_job.rb` —
  already do `agent.departments.active.first` in some code paths, i.e. already assume
  one department per agent in practice.
- 7 controllers nest routes under `ai_agents/:id/ai_departments/:id/...` (Tools,
  LeadVariables, DepartmentInboxes, DepartmentIntegrations, PlaybookVersions) plus
  `AiDepartmentsController` itself and `AiShadowRunsController` (filters/joins on
  `ai_department_id`).
- Frontend: `AiDepartmentDetail.vue` (~770 lines, dedicated route `ai_department_detail`)
  is the real "own department" screen — but `AiAgentDetail.vue` **already
  auto-provisions and hides** a single "default department" (`ensureDefaultDepartment`)
  and embeds `AiDepartmentDetail` inline via `embed-department-id`. The multi-department
  UX is already flattened at the product layer for the common case.

## 3. `Ai::DepartmentResolver` usage
Not a side path — it's on the hot path of every live/shadow message (via `Gateway`),
plus Copilot, the Test tab, and the follow-up fallback. Heavily exercised, but its
logic (single/inbox_mapping/classifier/default/fallback) collapses to a no-op the
moment there's exactly one department, which is the business's actual usage pattern.

## 4. Does data need to move up a level?
- **KnowledgeSource: no work needed.** Already fully account-scoped in the controller,
  `department_id` nullable and effectively unused — commit `74dc2f26`
  ("conhecimento compartilhado no nível da conta") already did this migration in practice.
- **Tool:** `ai_department_id` nullable already; low-effort to repoint at `ai_agent_id`.
- **Playbook, LeadVariable:** required FK to department — need an actual column
  migration (`ai_department_id` → `ai_agent_id`) plus a straightforward backfill
  (1 row per agent today, given the one-department-per-agent usage pattern).
- **DepartmentInbox:** fully redundant once department=agent 1:1 — inbox routing
  already exists independently at `Ai::AgentInbox`. Can simply be dropped.
- **DepartmentIntegration:** collapses into a straightforward Agent↔IntegrationLink
  join, or may be droppable if `Ai::Tool.integration_link_id` already covers the real
  need (worth a 10-minute check before implementing).

## 5. Spec/test churn
At the time of research, zero backend/frontend specs referenced `Ai::Department` or
`ai_department_id`, and there were no factories for `Ai::` models — since then this
session added real specs exercising `Ai::Department` directly (e.g.
`spec/jobs/ai/followup_conversation_job_spec.rb`, `spec/services/ai/python_orchestrator_client_spec.rb`).
**Re-check actual churn before starting** — it's no longer zero, though still likely small.

## 6. Serialization boundaries
- Internal-only crossings found: `ai_events.payload` jsonb persists `department_id`
  under the `department.resolved` event type (historical audit data — would need a
  compat read path or backfill note); `ai_runs.ai_department_id` is a queryable
  metrics column consumed by `AiShadowRunsController`; frontend axios calls send
  `ai_department_id` as a URL path segment on ~7 endpoints and `department_id` as a
  query param on `ai_agents#test` and `ai_shadow_runs#index`.
- **Needs re-verification**: whether `department_id`/`ai_department_id` crosses into
  the Python orchestrator's request/response payload (`Ai::PythonOrchestratorClient`,
  `ai-orchestrator/orchestrator.py`) — see the correction note above.

## Context that changes the calculus
- `docs/ai-core-audit.md` (2026-06-22, "Arquitetura congelada") explicitly states the
  Agent/Department separation is an **approved, frozen architectural decision from
  PR #77** — "não será refatorada." Removing Department reverses a deliberate,
  documented decision, not a cleanup of incidental cruft. Worth a conscious
  go/no-go conversation before starting, not just an engineering call.
- At the same time, recent commit history (`1b292ec9` "Custos sem departamentos",
  `74dc2f26` "conhecimento compartilhado no nível da conta") shows the team has
  already been steadily pulling functionality **out** of Department and up to
  Agent/Account level in practice — the codebase is mid-drift toward exactly the
  collapse being asked about.
- The whole module sits behind a per-account `ai_core` feature flag, default-off,
  which lowers migration/data-safety risk considerably.

## Scale assessment
Not "rename a column," and not a multi-week architectural migration either — the
domain is small and isolated (no Enterprise overlay involvement today, minimal test
suite, and mostly-internal serialization). Realistic characterization: **a multi-day,
single-engineer, well-scoped backend+frontend consolidation** (roughly 1–2 weeks
including the Playbook/LeadVariable data migration, DepartmentInbox/
DepartmentIntegration removal, collapsing the `department:` params in ~5 service-layer
methods to read straight off `Ai::Agent`, retiring ~7 nested routes/controllers, and
reworking `AiDepartmentDetail.vue` into agent tabs it's already halfway embedded into)
— plus a decision conversation, since it reverses a written, approved architecture call
rather than just deleting dead code.

## Suggested easy first step, if/when this gets picked up
`Ai::DepartmentInbox` looked fully redundant against `Ai::AgentInbox` even at research
time — worth a 10-minute recheck as the lowest-risk starting point when this is revisited.
