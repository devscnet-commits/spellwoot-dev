# Assessment: "Análises com IA" (Shadow) module after the Python migration (2026-08-18)

Scoping research only — no code changed. Written so this can be picked back up in a
later session without re-deriving it. Trigger: the business owner asked, after seeing
the "Ferramentas ausentes" section flag `salvar_memoria_ia`/`continuar_conversa` as
missing tools, whether this module needs refactoring now that the Python microservice
and the old workers are gone — "qual sua ideia de reformular o comportamento e
organização aqui."

## Headline

The "Ferramentas ausentes" false positive is real, but it's a *symptom*, not the
disease. The actual bug is bigger and more urgent than the two tool names in the
screenshot: **`Ai::Gateway`'s Python-orchestrator branch persists a `decision` jsonb
shape (`{'kind'=>'reply','text'=>...}`) that shares almost no keys with the shape the
entire "Análises" dashboard reads (`'decision'`, `'reply_text'`, `'tool'`,
`'confidence'`) — a shape left over from the old Ruby engine's `Ai::ModelRouter.decide`
output.** Because of this key mismatch, **every live, post-migration conversation run
is misclassified as "unanswered," with a blank proposed reply, no tool ever detected,
and no confidence ever read** — regardless of what the AI actually did. The numbers
Jaqueline is looking at (36×/11× for the two reserved tool names, and very likely most
of the rest of the "Resumo executivo") are dominated by stale pre-migration data, not
today's engine. This is close-to-zero-risk to fix for the two headline metrics
(confidence, reply visibility) — one field each, additive, no schema change — but the
"which tool/knowledge-source was used" signal genuinely does not exist in today's
Rails↔Python payload at all, and getting it back is a real (if small) cross-service
change, not a jsonb key rename.

## 1. Two independent modules share this screen, and only one of them is what you'd guess

Reading `AiShadows.vue`/`AiShadowRuns.vue` and their backends, "Análises com IA" is
actually two separate features glued into one screen by tabs:

- **"Analistas criados"** (`Ai::Shadow`, `app/models/ai/shadow.rb`,
  `Api::V1::Accounts::AiShadowsController`) — an admin creates a named "Analista" with
  freeform `instructions`, linked to a set of inboxes, scoped to observe AI and/or
  human handling. When a linked-inbox conversation resolves,
  `Ai::ShadowListener#conversation_resolved` → `Ai::ShadowEvalJob` →
  `Ai::ShadowEvaluator#evaluate` runs a **separate, independent LLM call** — it does
  **not** re-read anything from the real conversation's `Ai::Run` — via
  `Ai::ModelRouter.decide` (the **old, pre-migration Ruby engine method**, still alive
  because this is its only caller today), with its own judge prompt asking for
  `{"resolution":...,"confidence":...,"error_type":...,"issues":[...],"suggestions":[...]}`.
  It records a new `Ai::Run` with `run_type: 'shadow_eval'`, `mode: 'shadow'`.
- **"Análises"** (`Api::V1::Accounts::AiShadowRunsController#index`, the KPI/insights
  screen in the screenshot) — this is a **completely different code path that ignores
  `Ai::Shadow`/`Ai::ShadowEvaluator` entirely.** It queries `::Ai::Run.where(account_id:
  ...)` with **no `run_type` filter** — every run type in the window (`decision`,
  `shadow_eval`, `trivial_skip`, anything else) gets pulled into one bucket — and
  derives "Resumo executivo," "Lacunas de conhecimento," "Falhas de instrução," and
  "Ferramentas ausentes" straight from each run's `decision` jsonb and `error_type`/
  `knowledge_count` columns.

So an "Analista" you create today configures **only** the freeform judge prompt that
feeds a handful of `shadow_eval` runs (visible nowhere yet — no UI reads
`run_type: 'shadow_eval'` runs specifically). The KPI dashboard she's looking at is
driven almost entirely by ordinary customer-conversation runs (`run_type: 'decision'`),
whether or not any Shadow/Analista exists at all. **The "Analistas criados" tab and the
"Análises" tab are not really the same feature wearing two tabs — today they barely
talk to each other.**

## 2. The `decision` jsonb key mismatch — confirmed, file + line

`Ai::Gateway#run`, Python-orchestrator branch, `app/services/ai/gateway.rb:220-222`:

```ruby
run_record.update!(provider: 'openai', decision: { 'kind' => 'reply', 'text' => result[:reply] },
                    status: status, error_type: (status == 'error' ? 'provider_error' : nil))
emit(run_record, 'decision.made', { decision: { 'kind' => 'reply' }, source: 'python_orchestrator' }, run_id: run_record.id)
```

That's the **entire** `decision` payload written for every live/shadow-mode
conversation run today: two keys, `kind` and `text`.

`Api::V1::Accounts::AiShadowRunsController`, `app/controllers/api/v1/accounts/ai_shadow_runs_controller.rb`:

```ruby
# line 156
kind = (run.decision || {})['decision']       # reads 'decision', Gateway writes 'kind' -> always nil
# line 169
def reply_text(run) = (run.decision || {})['reply_text']   # Gateway writes 'text' -> always nil
# line 173
def tool_name(run) = (run.decision || {}).dig('tool', 'name')   # Gateway never writes 'tool' -> always nil
# line 177
def confidence(run) = (run.decision || {})['confidence']   # Gateway never writes 'confidence' -> always nil
```

Trace the effect of `classify(run)` (lines 153-166) for **every** real Python-orchestrator
run reaching line 220 of Gateway: `kind` is always `nil`, so none of the `'handoff'`,
`'close'`, `'invoke_tool'`, `'reply'` branches match, and the method falls through to
its final line — `'unanswered'`. That is not a rare edge case; it is the outcome for
**100% of live decision runs**, success or not. Consequently:

- **`reply_text`** is always blank → the run drill-down's "Resposta que seria enviada"
  shows "Nenhuma resposta proposta" for conversations that were, in fact, answered.
- **`tool_missing`** is always `false` for live runs (no `tool` key to compare against
  `department_tools`), so today's real conversations cannot possibly be the source of
  a "Ferramentas ausentes" entry.
- **`confidence`** is always `nil` → `low_confidence?` is always `false` → "Respostas
  de baixa confiança" / "Falhas de instrução" never fire from live data either.
- **`resolution` = `'unanswered'` for everything** → `knowledge_gap?` (which requires
  `resolution == 'unanswered'` plus a substantive question) fires for essentially
  every live, answered, substantive customer message. **"Lacunas de conhecimento" is
  not "fine as-is" as hypothesized going in — it is currently the most *inflated*
  metric on the whole screen**, because the classifier can't tell a genuine RAG miss
  from an ordinary answered turn; both look identical (`'unanswered'`) under this bug.

## 3. Where the two flagged tool names actually come from

Given §2, a real Python-orchestrator run can never populate `decision['tool']` — the
key doesn't exist in what Gateway writes, and (see §5) the Python service doesn't even
send tool-call info back to Rails to write. `Ai::Tester` (Teste tab) and
`Ai::ShadowEvaluator` both call `Ai::ModelRouter.decide` **without** `json: true` and
without offering the reserved control tools as real function-calling tools — so neither
produces a `tool_name`/`tool_input_json` pair for `Ai::ModelRouter.normalize_decision`
(`app/services/ai/model_router.rb:653-668`) to turn into a `'tool'` key, and
`Ai::Tester` doesn't even persist an `Ai::Run` at all.

The only remaining source: **`Ai::Run` rows created before the August migration**,
when `Ai::Gateway` still ran the old engine directly (`Ai::ModelRouter.call_with_tools`
/`decide(json: true)` against `Ai::DecisionSchema`, which — per this session's
established context — offered `salvar_memoria_ia`/`continuar_conversa` as real,
callable OpenAI functions). Those old runs genuinely have `decision['tool']['name'] ==
'salvar_memoria_ia'` because, at the time, the model really did call that tool for
real, and it really wasn't a configurable `Ai::Tool` row (it never was — it's one of
the 5 reserved control-tool names). `AiShadowRunsController#index` has no `run_type`
filter and no cutoff tied to the migration date, so as long as the selected window
(up to the 365-day cap) reaches back before the migration, those historical decisions
keep resurfacing as if they were current findings. **This could not be verified
against live data in this session** (no DB access from this environment — see note
below) but is the only path through the code that produces this exact signal, and it
fully explains why the counts (36×, 11×) look like accumulated history rather than a
handful of recent turns.

Separately — and this would apply going forward even after a fix — **these two names
are retired control mechanisms, not "tools an admin forgot to configure."**
`Ai::PythonOrchestratorClient::MEMORY_TOOL = 'salvar_memoria_ia'` and `CONTINUE_TOOL =
'continuar_conversa'` (`app/services/ai/python_orchestrator_client.rb:60,67`) are
filtered out of the tools list before it ever reaches OpenAI; Structured Outputs
replaced the mechanism they used to serve. `Api::Internal::AiExecuteToolController`
still recognizes the *name strings* server-side (for the historical webhook contract),
but the model can no longer "suggest" them as an unmet capability the way a real
missing `Ai::Tool` can. Whatever fixes §2, this dashboard should also treat the 5
reserved names (`ADVANCE_STEP_TOOL`, `RESOLVE_TOOL`, `TRANSFER_TOOL`, `CONTINUE_TOOL`,
`MEMORY_TOOL`) as a permanent exclude-list for "missing tool" purposes — they can never
legitimately be "configured" by an admin, so flagging them as a gap to close is asking
her to fix something that isn't fixable.

*(Note on evidence: this session's environment has no working Ruby/rbenv installed —
`bundle exec rails runner` failed with "version 3.4.4 is not installed" — so the exact
row counts/timestamps for the historical-data theory above could not be queried
directly. The code-path argument in this section is airtight (there is no other route
to a populated `tool` key), but if you want the literal proof before acting, run:
`Ai::Run.where("decision->'tool'->>'name' IN (?)", ['salvar_memoria_ia','continuar_conversa']).pluck(:id, :run_type, :created_at)`
and confirm every row predates the Python migration.)*

## 4. "Analistas criados" — what the config actually does today

`Ai::Shadow`'s schema (`app/models/ai/shadow.rb`): `name`, `instructions` (text),
`scope` (jsonb: `observe_ai`/`observe_human`), `data_signals` (jsonb), `status`. The
create/edit form (`AiShadows.vue`) additionally renders a "O que observar" checklist
(SIGNALS: Dúvidas não respondidas / Erros / Baixa confiança / Conhecimento faltante /
Ferramenta que faltou / Temas recorrentes) that maps to `data_signals`, plus a
"suggestions" panel that just appends canned phrases into the `instructions` textarea
when clicked (`SUGGESTIONS_HINT`).

Grepped across `app/`: **`data_signals` is written by the controller
(`ai_shadows_controller.rb:49`) and declared on the model, but read nowhere else in the
codebase.** Neither `Ai::ShadowEvaluator` nor `Ai::ShadowEvalJob` nor
`AiShadowRunsController` ever inspects it. This is the same shape of problem the sibling
Operation Profiles assessment found with `budget_usd`/`routing_strategy`: a set of
checkboxes that look like they configure what an Analista watches for, persisted
faithfully on every save, doing precisely nothing. The only field that is genuinely
load-bearing is `instructions` (folded into the judge prompt) and `scope` (used by
`ShadowEvalJob#scope_matches?` to gate AI-handled vs human-handled).

So to directly answer the task's question 4: the Analista's configuration model does
**not** carry legacy-engine assumptions about individual tool-calls/worker-outputs —
it's already just "freeform instructions + a judge LLM call," which maps fine onto a
Structured-Outputs world. Its actual problem is unrelated to the migration: half its
form (`data_signals`) is inert, and — per §1 — its output (`run_type: 'shadow_eval'`
runs) isn't consumed by the "Análises" tab at all today, so creating an Analista and
tuning its instructions currently has **no visible effect anywhere in the product.**

## 5. Does shadow-mode data generation still work? Yes — the gap is entirely downstream

Per the task's question 5: shadow-mode runs (`Ai::AgentInbox` mode `'shadow'`) still go
through the full live `Ai::Gateway` → `Ai::PythonOrchestratorClient` pipeline — a real
OpenAI call happens every turn, `@acts_live` gates only the side effects (reply send,
tool execution, breaker writes), exactly as the Gateway's own header comment states
("NUNCA responde, NUNCA executa uma tool... só registra intenção"). **The underlying
runs are fine.** The problem is entirely in what gets written into `decision` (§2) and
in what the Python service reports back at all (below) — not in whether shadow turns
happen.

The deeper limit, confirmed in `Ai::PythonOrchestratorClient#perform`
(`app/services/ai/python_orchestrator_client.rb:117-123`): the only fields the Python
service returns to Rails per turn are `reply`, `conversation_id`, `byok_fallback`,
`confidence`, `transferred`. **There is no field for "which tool got called," "how many
knowledge chunks were retrieved," or "which tool the model wanted but wasn't offered."**
Under the old engine, Rails ran the tool-call loop itself (`Ai::ModelRouter.call_with_tools_responses_api`)
and could inspect every call. Under the Python orchestrator, that entire loop — native
tools, `consultar_conhecimento`, real `Ai::Tool` calls — now runs **inside Python**,
and only the final text and a couple of scalars cross back. This means:

- `result[:confidence]` (the real `confianca` field, Structured Outputs) **is computed
  and used every turn** (`Ai::Gateway#low_confidence?`, line 512) but is **never
  persisted** — not into `decision`, not into a dedicated column, not into an event
  payload (except transiently inside `handoff.low_confidence`, and only when a handoff
  actually fires). It is thrown away the moment the turn completes normally.
- `knowledge_count` **is a real column** on `Ai::Run` (`default(0), not null`) that the
  dashboard already reads for the knowledge-vs-instruction split (line 162), but
  grepped across `app/`, **nothing writes to it, ever** — it's permanently 0, same
  dead-field pattern as `Ai::OperationProfile#budget_usd` from the sibling assessment.
- **No tool-name signal crosses back at all.** Fixing the `decision` key mismatch
  (§2) recovers `reply_text`/`resolution`/`confidence` for free — those all already
  exist in Rails, just under the wrong keys. It does **not** recover "Ferramentas
  ausentes" or a correct "knowledge" vs "instruction" split for real tool/RAG usage,
  because that data genuinely isn't sent by `orchestrator.py` today.

## 6. Spec coverage

Only one spec file touches this module at all: `spec/jobs/ai/shadow_eval_job_spec.rb`
— 4 examples, all about job wiring (does it create a run, does it skip inactive
Shadows/wrong inbox/scope mismatch). Its `Ai::ModelRouter.decide` stub returns
`decision: { 'resolution' => 'closed', 'confidence' => 0.9, 'issues' => [] }` directly
as a Hash — i.e. it tests the `shadow_eval` wiring, not the JSON contract shape, and
never exercises `Ai::ShadowEvaluator`'s prompt-building or error normalization
directly. **Zero coverage** of `Ai::ShadowEvaluator` as a unit, `Ai::Shadow` the model,
and — critically — **zero coverage of `AiShadowRunsController` at all**: no spec would
have caught the `decision` key mismatch in §2, because nothing asserts what `classify`/
`tool_name`/`reply_text`/`confidence` return against a `decision` shaped the way
`Ai::Gateway` actually writes it today. This is exactly the kind of drift a single
controller spec with a Python-shaped `decision` fixture would have caught immediately.

## Scale assessment

**Two different sizes of work bundled in one ask.** The `decision`-shape fix (§2) is a
same-day, low-risk patch: extend the one `run_record.update!` call in
`Ai::Gateway#run` to carry the fields the dashboard already expects
(`'decision' => 'reply'`, `'reply_text' => result[:reply]`, `'confidence' =>
result[:confidence]`), which the Gateway already has in scope at that line — no schema
change, no Python change, additive only. The tool-visibility/knowledge-count gap (§5)
is a real, if still small, **two-service change**: `orchestrator.py` would need to
report back which tool(s) it called (or wanted to call and couldn't) and how many
knowledge chunks it used, and `Ai::PythonOrchestratorClient`/`Ai::Gateway` would need
to plumb that through into `decision`/`knowledge_count`. Realistic estimate:

- **Fix decision-shape + reserved-name exclude-list + dead `data_signals` cleanup**:
  **1-2 days, single engineer.** No product conversation required — these are
  corrections back to already-designed behavior, not new scope.
- **Recover real tool/knowledge signal from Python**: **a few days, spanning
  `ai-orchestrator/` and Rails**, closer in shape to a small feature than a bugfix —
  worth scoping separately once the above ships and she can see whether the corrected
  dashboard (confidence + resolution + reply visible, "Ferramentas ausentes" no longer
  showing stale/unfixable names) is already useful enough without it.
- **Reconnecting "Analistas criados" to "Análises"** (deciding whether Shadow judge
  findings should feed the KPI screen, replace it, or stay a separate future surface)
  is a product decision, not an engineering one — see recommendation below.

## What's actually fine as-is

- Shadow-mode run generation itself (§5) — the pipeline, the gating, the "zero side
  effects" guarantee. No changes needed.
- `Ai::Shadow.scope` (`observe_ai`/`observe_human`) — genuinely wired, does what it
  says.
- The controller's noise-filtering logic for knowledge gaps (attachment placeholders,
  greeting stems, `MIN_GAP_LENGTH`) — well-reasoned, orthogonal to the bug in §2, keep
  it exactly as-is once `resolution` is computed correctly.
- The account-wide window/pagination/facet plumbing in `AiShadowRunsController` — solid
  engineering, no complaints; the bug is entirely in which fields get read out of
  `decision`, not in how the screen is built around them.

## Recommendation

Do not wait for a "big redesign" conversation before fixing the part that's a plain
bug. Suggested order:

1. **Fix the `decision` key mismatch in `Ai::Gateway#run` (§2)** — add
   `'decision' => 'reply'`, `'reply_text' => result[:reply]`, `'confidence' =>
   result[:confidence]` to the existing `run_record.update!` call. This alone fixes
   "Falhas de instrução," makes "Resposta que seria enviada" show real replies again,
   and stops "Lacunas de conhecimento" from over-counting every answered conversation
   as a gap. Pure bugfix, no product decision needed.
2. **Add the 5 reserved control-tool names as a permanent exclude-list** in
   `tool_name`/`tool_insights` (or wherever "missing tool" gets computed) — they can
   never be a legitimate "configure this" gap. Small, no product decision needed.
3. **Delete `data_signals`** from `Ai::Shadow`/`AiShadowsController`/`AiShadows.vue`
   (or wire it in, but nothing today reads it and there's no evident plan to) — same
   "safe delete, confirmed via grep" category as the sibling doc's dead fields.
4. **Bring her one product question before going further**: now that "Análises" is
   readable again, does she want "Analistas criados" (the freeform judge) to feed that
   same screen (e.g. a dedicated section sourced from `run_type: 'shadow_eval'` runs),
   replace parts of it, or stay a separate, still-unsurfaced capability? Today creating
   an Analista has no visible product effect, which is worth her explicit sign-off
   before anyone spends time either wiring it in or ripping it out.
5. **Only after (1)-(4)**, scope the cross-service work to get real tool/knowledge
   signal back from `orchestrator.py` (§5) — worth doing, but it's the one item here
   that isn't a same-day fix, and it's much easier to size correctly once she's looking
   at a dashboard that's no longer structurally broken by the `decision` key mismatch.
