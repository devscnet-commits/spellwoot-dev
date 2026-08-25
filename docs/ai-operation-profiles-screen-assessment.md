# Assessment: refactoring the "Perfis de Operação" screen (2026-08-18)

Scoping research only — no code changed. Written so this can be picked back up in a
later session without re-deriving it. Trigger for the question: the business owner
(non-developer, testing live) flagged `AiProfiles.vue` as "precisa ser refatorada para
a nova realidade onde nem tem mais workers e está bem bagunçada com as validações da
época que era somente em ruby" — this is a scoping pass, same pattern as the Department
removal assessment, before anyone touches the screen.

## Headline

The screen is small (one 539-line Vue file, a 67-line model, a 58-line controller) and
**not architecturally entangled** — no Enterprise overlay, no other screen embeds it,
no data migration required to clean it up. But "bagunçada" undersells it: the messiest
part isn't leftover Ruby-worker validation (the model already dropped that in the
migration) — it's a **hidden routing feature with no UI control that still round-trips
on every save**, a **budget field with zero enforcement anywhere in the codebase**, and
a **provider dropdown that lets an admin configure something the live engine cannot run
at all**. Those are worse than dead code: they're live-looking controls a non-developer
would reasonably trust.

## 1. What the screen edits, and whether it's still real

| Field (form) | Sent as | Live in Python-orchestrator path? | Status |
|---|---|---|---|
| `name` | `name` | n/a (label only) | Real |
| `preset` (Econômico/Balanceado/Premium/Customizado) | `tier` | n/a (UI convenience) | Real |
| `supervisor_provider` | `supervisor_provider` | **Only `openai` actually works** (see §3) | Real but misleading for 4/5 options |
| `supervisor_model` | `supervisor_model` | Yes — sent to orchestrator.py as `model` | Real |
| `temperature_position` (slider 0–100) | `temperature_position` | Yes — `Ai::TemperatureMapper` translates to real temperature, sent every turn | Real, but no reasoning-model guard (see §3) |
| `route_high`/`route_low`/`cheap_provider`/`cheap_model`/`premium_provider`/`premium_model` | `routing_strategy` jsonb | **No** — never read by the live Gateway/Python path | **Dead in production traffic; also has no UI (see §2)** |
| `budget_usd`, `on_limit` | `budget` jsonb | **No** — never read anywhere in `app/` outside this screen's own controller/model annotation | **Fully dead — no enforcement exists** |
| (nothing — intentionally omitted) | `worker_overrides` | Mixed — see §4 | Partially dead, one live key has no UI at all |

`supervisor_temperature` (the old raw 0–2 column) is in the DB and still validated by
the model, but the frontend never sends it and no backend code reads it — confirmed by
grep across `app/`. It is 100% dead weight: a column, a `NOT NULL` constraint, and a
`validates :supervisor_temperature, numericality: ...` rule doing nothing except being
able to reject a save if someone hits the API directly with an out-of-range value nobody
asked for.

## 2. The invisible routing section — the real "bagunça"

`AiProfiles.vue`'s `form` reactive object carries `route_high`, `route_low`,
`cheap_provider`, `cheap_model`, `premium_provider`, `premium_model` (lines 64–69),
populates them from the loaded profile in `openEdit` (lines 165–170), and sends them
as `routing_strategy` on every save (lines 200–207) — **but there is no `<Input>`,
`<Select>`, or any markup anywhere in the 539-line template that lets a user see or
edit these six fields.** They only ever get a real value two ways: (a) whatever a
profile already had in the database before this UI was stripped out, silently
preserved and re-saved on every subsequent edit, or (b) `applyPreset()` overwriting
them to mirror the single supervisor model (explicitly commented "One model per
level: cheap/premium mirror the single model (no routing)" — i.e. not real routing
at all).

The i18n file (`app/javascript/dashboard/i18n/locale/en/aiAgents.json`) still carries
a full, translated `AI_PROFILES.ROUTING.*` block — TITLE, DESCRIPTION, HIGH, LOW,
CHEAP_PROVIDER, CHEAP_MODEL, PREMIUM_PROVIDER, PREMIUM_MODEL, EXPLAINER — none of it
referenced by the component. This is the clearest evidence of an in-progress ripout:
someone removed a "Estratégia de roteamento" section from the template but left its
data plumbing and its copy in place.

**Is `routing_strategy` load-bearing anywhere?** Only in `Ai::Tester` (the "Teste" tab
dry-run simulator, `app/services/ai/tester.rb`), which calls `Ai::RoutingStrategy.decide`
to simulate cache/cheap/premium routing over RAG confidence — a legacy code path that
still uses `Ai::PromptCompiler` and `Ai::ModelRouter.decide` directly, not the Python
orchestrator. Real customer conversations (`Ai::Gateway` → `Ai::PythonOrchestratorClient`)
never look at `routing_strategy` at all. So today this field affects nothing except the
"Teste" tab's simulated output.

## 3. The provider dropdown makes a promise the engine can't keep

The Advanced → Modelo da IA section offers 5 providers (anthropic, openai, google,
openrouter, groq) as equally valid choices for `supervisor_provider`, with Groq
restricted to an approved-models allowlist for safety reasons (a real, well-documented
guard — see §6). But `app/services/ai/python_migration_auditor.rb` — a read-only audit
module written by this same team during the migration — states this directly:

> "orchestrator.py tem um único client hardcoded (`_client = OpenAI(...)`) — um
> department cujo `Ai::OperationProfile#supervisor_provider` NÃO é 'openai' QUEBRA
> por completo no Python."

Confirmed at the Python layer too (`ai-orchestrator/orchestrator.py`): `provider` is
"accepted and logged ONLY — no dispatch yet: multi-provider routing doesn't exist, only
multi-KEY (BYOK, same provider) via `account_api_key`." So today, picking Anthropic,
Google, OpenRouter, or Groq as the supervisor provider for a profile that's actually
used by a live department **breaks that department's conversations entirely** — with
no warning anywhere in the UI. This is not a cosmetic leftover; it's a working control
that produces a broken product outcome, on the single most prominent field in the form.

## 4. `worker_overrides`: mostly dead, one live gap

The screen's own comment (lines 194–199) is accurate that no worker UI is rendered
anymore, but the column is still read at runtime — unevenly:

| `worker_overrides` key | Read by | Actually reachable from a live request? |
|---|---|---|
| `ocr` | `Ai::Workers::MediaProcessor.ocr_worker` | **No.** `Ai::Gateway` is the only caller of `MediaProcessor.process`, and it always passes `skip_vision: true` — the image and scanned-PDF-vision branches both short-circuit to `nil` before `ocr_worker` is ever consulted. (OpenAI reads pixels natively in the Python path now.) |
| `summary` | `Ai::Workers::Summary` via `Ai::StateManager#update_memory` | **No.** `update_memory` is never called by `Ai::Gateway`, `Ai::PythonOrchestratorClient`, or `Api::Internal::AiExecuteToolController` — grepped across `app/`, zero call sites. |
| `capture_judge` | `Ai::Workers::CaptureJudge` via `Ai::StateManager#run_turn_judge`; `Ai::TurnCapture` | **No.** `run_turn_judge`, `track_step`, and `claim_turn` (the only entry points into `Ai::TurnCapture`) have zero call sites anywhere in `app/`. |
| `trivial_gate` | `Ai::Gateway#trivial_gate_on?` | **Yes.** Called directly in the live `Ai::Gateway#run` pipeline (Camada 0 — trivial-turn triage) on every message. |
| `native_tools` | mentioned in the screen's own comment as a UI-less key | Not found read anywhere in `app/` today — likely aspirational/reserved. |

So of the five worker-era keys still nested under `worker_overrides`, four are
confirmed dead in the live Python path (their only Ruby callers are themselves
unreachable), and one (`trivial_gate`) is genuinely load-bearing today but has **no
UI anywhere** — an admin can only turn it on by hitting the API directly with
`worker_overrides: { trivial_gate: { mode: 'on' } }`.

## 5. Temperature slider vs. reasoning-family models — confirmed live gap

Per the product owner's separately-flagged concern: reasoning-family models (o1/o3/
gpt-5-class) reject any `temperature` other than 1. This screen intersects directly:

- `supervisor_model` is free text for every provider except Groq — an admin can type
  `o3-mini` or `gpt-5` into the OpenAI model field today.
- The temperature slider defaults to position 20 (`temperature_position: 20` in
  `blank()`), which `Ai::TemperatureMapper` resolves to **≈0.28** for `openai`
  (interpolating its `[[0,0.0],[50,0.7],[100,1.3]]` anchors) — not 1.
- `ai-orchestrator/orchestrator.py` sends `temperature` on every call whenever it is
  not `None` (`_turn_kwargs`) — there is no reasoning-model name check anywhere in the
  Python service, `Ai::TemperatureMapper`, or `Ai::ModelRouter`.
- The UI shows no warning when a reasoning-family model name is typed in.

Net effect: nothing stops an admin from configuring a profile that will 400 at
runtime the moment a real conversation hits it, and nothing in the flow tells them
why. This is the same shape of problem as §3 (a control that looks valid but silently
produces broken production behavior) and should be fixed alongside it.

The other separately-flagged cost concern — cached tokens discounted off input cost
instead of the OpenAI-discounted cached rate (`Ai::ModelRouter.estimate_cost`) — does
**not** intersect this screen; the profile only supplies which model/provider feeds
that calculation, it doesn't configure pricing. No action needed here for that one.

## 6. What's actually fine as-is

- **`temperature_position` + `Ai::TemperatureMapper`**: a deliberate, well-reasoned
  redesign (abstract 0–100 slider → provider-correct real temperature) that replaced
  the legacy raw-temperature field. Genuinely load-bearing in the live path. Keep.
- **Groq allowlist** (`GROQ_APPROVED_MODELS`, UI dropdown + `groq_supervisor_model_approved`
  model validation): a real, currently-relevant safety control — a Groq model
  recommended competitors in a smoke test, and the defense-in-depth (closed dropdown +
  server-side validation against direct API saves) is exactly the right shape. Keep,
  and treat the frontend/backend list as a synced pair going forward.
- **Preset system** (Econômico/Balanceado/Premium/Customizado): a clean, current
  product concept — "one model per level, no routing" — matches today's single-model-
  per-turn architecture. Keep.
- **Controller**: small, no worker-era cruft of its own; the only issue is that
  `profile_params` still permits the dead `supervisor_temperature` column (§1) and
  `jsonb_params` will happily persist a directly-posted `worker_overrides` key that
  has no UI anywhere (§4) — neither is a design flaw in the controller itself, both
  are downstream of the model/schema decisions above.

## 7. Spec coverage

`spec/models/ai/operation_profile_spec.rb` is the only spec file for this model or its
controller. It tests exactly one thing: the Groq-approved-model validation (5 examples,
all Groq-safety-related). There is **zero coverage** of `temperature_position` bounds,
`routing_strategy`/`budget` jsonb behavior, the controller's params filtering, or
`worker(key)`. No controller spec exists at all. Any refactor here is happening in
close-to-zero-test territory — safe in the sense that nothing will "break a test suite,"
risky in the sense that nothing will catch a regression either. Worth adding a
controller spec and a couple of model specs (jsonb round-trip, `worker(key)` behavior)
as part of whatever cleanup gets picked up, not as a prerequisite to starting.

## 8. Frozen-architecture context

`docs/ai-core-audit.md` (2026-06-22) declares the Agent/Department/Perfil Operacional
three-way split "correta e não será refatorada" — the same frozen decision flagged in
the Department removal assessment. It describes Perfil Operacional as "Supervisor +
workers + roteamento por confiança + orçamento. Reutilizável entre agentes." That
description is now **stale**, not wrong-headed: the frozen decision protects the
*concept* (a reusable, provider-agnostic strategy object separate from Agent/Department),
not the specific field list the June audit wrote down before the August worker-removal
and Python migration. Cleaning up this screen doesn't reverse that decision — it brings
the concept's implementation back in line with what the June doc already called out as
the right shape, using today's field set instead of the pre-migration one.

## Scale assessment

**Quick-to-medium cleanup, not a multi-day project.** Unlike the Department removal
(which touches 7+ controllers, required models, and a documented architectural
reversal), this is one screen, one model, one controller, no Enterprise overlay, no
required-FK data migration, and zero downstream consumers to coordinate with. Realistic
estimate: **1–3 days, single engineer**, once each item below gets a go/no-go decision
(the decisions are the actual scope — the code changes themselves are small):

1. **Decide the fate of routing_strategy** (§2) — either build the missing UI (if
   confidence-based cache/cheap/premium routing is a real roadmap item worth
   resurrecting for the live path) or delete the fields, the six-key jsonb shape, and
   the orphaned `AI_PROFILES.ROUTING.*` i18n block outright. Given it currently affects
   nothing but a dry-run test tab, deletion is the lower-risk default unless someone
   confirms real product intent to route live traffic this way.
2. **Decide the fate of `budget`** (§1) — either wire real monthly-spend enforcement
   into `Ai::Gateway` (the `on_limit: stop/downgrade/alert` semantics already read well
   as a spec) or remove the UI/field entirely so the screen stops implying a control
   that doesn't exist. Leaving it as-is is the one option that's actively bad — it's a
   number an admin sets that does nothing, in a "Orçamento" section they'll trust.
3. **Fix or gate the provider dropdown** (§3) — cheapest fix: restrict the dropdown to
   `openai` until the Python orchestrator actually dispatches by provider, with a note
   explaining why (BYOK key rotation for OpenAI already works; provider *switching*
   doesn't). Alternative: keep the dropdown but add a clear inline warning for
   non-OpenAI selections. Either is small; leaving it exactly as-is is not recommended.
4. **Add a reasoning-model guard** (§5) — smallest fix in this list: either detect
   known reasoning-model prefixes (`o1`, `o3`, `gpt-5`, etc.) in `supervisor_model` and
   force temperature to 1 / omit it, or surface a warning in the UI when the slider
   isn't at the "rigid" default for such a model. This should probably be fixed
   alongside the ModelRouter cached-token cost issue the owner flagged separately,
   since both are in the same "silent runtime 400 / cost surprise" family, even though
   they're different code paths.
5. **Drop dead weight**: `supervisor_temperature` column + validation (§1), the
   `ocr`/`summary`/`capture_judge` `worker_overrides` read paths that have no live
   caller (§4) — safe deletes, confirmed via full-codebase grep, no product decision
   needed.
6. **Decide `trivial_gate`'s visibility** (§4) — it's real and live but has zero UI;
   either add a toggle (simplest: a checkbox in Advanced) or explicitly leave it
   API-only with a code comment explaining why, so the next person doesn't rediscover
   this gap from scratch.

## Recommendation

Do the deletions (item 5) and the reasoning-model guard (item 4) first — they're pure
upside, no product conversation required, and item 4 in particular closes a live
"silent 400 in production" hole. Then bring items 1–3 and 6 to the product owner as a
short list of yes/no questions before writing any more code — each one is a real
"does this still need to exist / do we want to fix or hide it" call, not an engineering
judgment call, and answering them first avoids rebuilding UI for a routing feature (item
1) only to delete it again next quarter, or shipping budget enforcement nobody asked
for. Suggested order: (5) dead-code deletes → (4) reasoning guard → product
conversation on (1)/(2)/(3)/(6) → implement whichever way that conversation lands.
