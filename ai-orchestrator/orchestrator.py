import json
import logging

from openai import OpenAI

import config
import tools

logger = logging.getLogger("ai_orchestrator")

_client = OpenAI(api_key=config.OPENAI_API_KEY)

# Structured-output contract every turn must return (Ai::PythonOrchestratorClient's system_prompt
# spells this exact shape out to the model — see #structured_output_instruction). Replaces
# function-calling for data collection and step/flow control: the old design let the model call a
# no-op tool ("continuar_conversa") to satisfy tool_choice="required" while CLAIMING in text that it
# saved a datum it never actually registered via a "registrar_*"/"salvar_memoria_ia" call — nothing
# persisted, the next turn re-asked (the live loop bug this refactor exists to kill). Now saying
# something was saved is structurally impossible without putting it in "dados_coletados": that field
# IS the save, decided by Python from the parsed JSON, not by whether the model bothered to call a tool.
MENSAGEM_KEY = "mensagem_para_cliente"
DADOS_KEY = "dados_coletados"
AVANCAR_KEY = "avancar_etapa"
TRANSFERIR_KEY = "transferir_humano"
ENCERRAR_KEY = "encerrar_atendimento"
HANDOFF_SUMMARY_KEY = "handoff_summary"

# Same tool_name strings Api::Internal::AiExecuteToolController already recognizes (and already
# recognized before this refactor — see Ai::PythonOrchestratorClient::MEMORY_TOOL/ADVANCE_STEP_TOOL/
# TRANSFER_TOOL/RESOLVE_TOOL). TRANSFER_TOOL/RESOLVE_TOOL are pre-sanitized ("." -> "_",
# Ai::ToolNameSanitizer) because the controller compares against the SANITIZED name for those two.
MEMORY_TOOL = "salvar_memoria_ia"
ADVANCE_STEP_TOOL = "avancar_etapa"
TRANSFER_TOOL = "conversation_transfer"
RESOLVE_TOOL = "conversation_resolve"

# No longer offered as OpenAI function tools: the model now expresses these via the JSON reply itself
# (see the keys above), not a tool call. "registrar_*" (one synthesized tool per known attribute,
# Ai::StepCaptureTool) is superseded the same way "salvar_memoria_ia" is — "dados_coletados" is a
# free-form {chave: valor} bag, so a dedicated tool per attribute buys nothing extra. Rails
# (Ai::PythonOrchestratorClient#tools_schema) still computes and sends these — left alone there to
# keep this a Python-side contract change — so they're filtered out here before ever reaching OpenAI.
# Anything else in tools_schema (admin-configured webhooks/integrations, Ai::Tool rows) is a REAL
# action, not data collection/flow control, and stays as a normal function-calling tool.
_CONTROL_TOOL_NAMES = {"continuar_conversa", MEMORY_TOOL, ADVANCE_STEP_TOOL, TRANSFER_TOOL, RESOLVE_TOOL}
_CAPTURE_TOOL_PREFIX = "registrar_"


def _is_superseded_tool(name: str) -> bool:
    return name in _CONTROL_TOOL_NAMES or name.startswith(_CAPTURE_TOOL_PREFIX)


# OpenAI's text.format=json_object requires the word "json" to appear in the INPUT messages
# themselves — live 400 confirmed it: "Response input messages must contain the word 'json' in some
# form to use 'text.format' of type 'json_object'." `instructions` (system_prompt) doesn't count,
# no matter how much it talks about JSON — a plain "Oi" as the whole input 400s every time. Sent as
# its OWN separate input item (not prefixed onto the customer's message) so user_input reaching the
# model — and whatever OpenAI stores server-side for previous_response_id — stays byte-identical to
# what the customer actually typed.
_JSON_FORMAT_REMINDER = {
    "role": "user",
    "content": "Lembrete de formato: sua resposta final a este turno deve ser SEMPRE o objeto JSON "
               "definido nas instructions — nunca texto livre.",
}


def _build_input(user_input: str, image_urls: list[str] | None):
    """Always a list (never a bare string, unlike before) — the json-format reminder item goes first,
    then the customer's own turn: plain text, or a multimodal input_text/input_image(s) list when
    there's something to see this turn — a WhatsApp photo, and/or a scanned document's rasterized
    pages (base64 data URIs, Ai::Workers::MediaProcessor.pending_vision_images) — so the model's own
    vision reads them directly in THIS SAME governed turn instead of relying on a separate,
    context-blind captioning call folded into user_input as text (that's what previously let a CNH's
    "1997" get misread as "1991" by a call that had no idea what data the step even needed)."""
    if not image_urls:
        return [_JSON_FORMAT_REMINDER, {"role": "user", "content": user_input}]

    content = [{"type": "input_text", "text": user_input}]
    content += [{"type": "input_image", "image_url": url} for url in image_urls]
    return [_JSON_FORMAT_REMINDER, {"role": "user", "content": content}]


def _build_tools(tools_schema: list, vector_store_id: str | None) -> list:
    openai_tools = []
    if vector_store_id:
        openai_tools.append({"type": "file_search", "vector_store_ids": [vector_store_id]})

    for tool in tools_schema:
        if _is_superseded_tool(tool["name"]):
            continue
        openai_tools.append({
            "type": "function",
            "name": tool["name"],
            "description": tool.get("description", ""),
            # OpenAI's function-calling schema requires "parameters" — tools_schema arrives from
            # Rails keyed as "input_schema" (Ai::Tool's own field name), so this is the one place
            # that translation happens.
            "parameters": tool["input_schema"],
        })
    return openai_tools


def run_conversation(
    *,
    ticket_id: int,
    ai_department_id: int,
    mode: str,
    system_prompt: str,
    tools_schema: list,
    vector_store_id: str | None,
    user_input: str,
    previous_response_id: str | None,
    model: str | None = None,
    temperature: float | None = None,
    image_urls: list[str] | None = None,
) -> tuple[str, str]:
    """Owns the OpenAI Responses API turn. The model's ONLY output is the structured JSON contract
    (text.format=json_object) — control flow (save/advance/transfer/close) is decided by Python from
    the parsed JSON and dispatched to Rails' webhook, never by which tool the model chose to call.
    Real (admin-configured) business tools are still offered as function tools for genuine external
    actions. Always returns (reply_text, response_id) — including when parsing fails or
    MAX_TOOL_ITERATIONS is hit — so the caller (main.py) never has to special-case a cut-off turn,
    only real transport/API failures."""
    openai_tools = _build_tools(tools_schema, vector_store_id)
    # Multi-tenant: Rails resolves this per Account (Ai::OperationProfile); config.OPENAI_MODEL is
    # only the fallback for a tenant with no profile, never a global override.
    resolved_model = model or config.OPENAI_MODEL

    logger.info(
        "ticket_id=%s model=%s function tools sent to OpenAI: %s",
        ticket_id, resolved_model, json.dumps(openai_tools, ensure_ascii=False),
    )

    create_kwargs = {
        "model": resolved_model,
        "instructions": system_prompt,
        "input": _build_input(user_input, image_urls),
        "tools": openai_tools,
        # Responses API structured-output param — NOT "response_format" (that's the older Chat
        # Completions name; passing it here would raise a TypeError on this SDK/API instead of
        # working). json_object (not a strict json_schema) because the contract only needs to be
        # valid JSON with the documented keys, and system_prompt already spells the exact shape.
        "text": {"format": {"type": "json_object"}},
    }
    # Omitted entirely (not sent as null) when absent, so OpenAI starts a fresh conversation
    # instead of trying to resume a previous_response_id that doesn't exist, and so temperature
    # falls back to OpenAI's own default instead of us hardcoding one.
    if previous_response_id:
        create_kwargs["previous_response_id"] = previous_response_id
    if temperature is not None:
        create_kwargs["temperature"] = temperature

    response = _client.responses.create(**create_kwargs)

    # Real business tools only (control/capture tools are never in openai_tools anymore) — same
    # one-round shape as before: collect whatever the model called in parallel, feed the results
    # back, and the followup is expected to carry the final structured JSON reply.
    for _ in range(config.MAX_TOOL_ITERATIONS):
        function_calls = [item for item in response.output if item.type == "function_call"]
        if not function_calls:
            break

        tool_outputs = []
        for call in function_calls:
            arguments = json.loads(call.arguments or "{}")
            try:
                result = tools.execute_tool(
                    ticket_id=ticket_id,
                    ai_department_id=ai_department_id,
                    tool_name=call.name,
                    arguments=arguments,
                    mode=mode,
                )
            except tools.ToolExecutionError as e:
                # Fed back to the model as the tool's own output (not raised) so a single failing
                # tool degrades the turn instead of aborting it — the model can apologize/retry.
                result = {"error": str(e)}

            tool_outputs.append({
                "type": "function_call_output",
                "call_id": call.call_id,
                "output": json.dumps(result),
            })

        followup_kwargs = {
            "model": resolved_model,
            "previous_response_id": response.id,
            # tool_outputs alone (function_call_output items) has no guaranteed "json" text in it —
            # same 400 risk as the plain-text turn above, so the reminder rides along here too.
            "input": [_JSON_FORMAT_REMINDER, *tool_outputs],
            "text": {"format": {"type": "json_object"}},
        }
        if temperature is not None:
            followup_kwargs["temperature"] = temperature

        response = _client.responses.create(**followup_kwargs)

    payload = _parse_structured_reply(response.output_text)
    if payload is None:
        # Last-resort guardrail: either the turn cut off (MAX_TOOL_ITERATIONS) still holding a
        # function call, or the model somehow returned unparseable JSON. Chained via
        # previous_response_id (full turn history is already there) with NO tools — a function call
        # is off the table, so this call can't itself degrade into another empty/non-JSON turn.
        response = _client.responses.create(
            model=resolved_model,
            previous_response_id=response.id,
            input="Responda ao cliente agora, no formato JSON definido no system prompt, com base no "
                  "que você acabou de fazer.",
            text={"format": {"type": "json_object"}},
            **({"temperature": temperature} if temperature is not None else {}),
        )
        payload = _parse_structured_reply(response.output_text)

    if payload is None:
        logger.warning(
            "response_id=%s: structured reply parsing failed twice; using the static fallback",
            response.id,
        )
        payload = {}

    reply_text = _dispatch_structured_reply(
        payload, ticket_id=ticket_id, ai_department_id=ai_department_id, mode=mode,
    )
    return reply_text, response.id


def _parse_structured_reply(text: str | None) -> dict | None:
    """None on blank/invalid/non-object JSON — every caller treats that as "no usable reply yet",
    never as an empty-but-valid turn (an empty object would silently mean "nothing to save, don't
    advance, don't transfer, blank message" instead of triggering the force-reply guardrail)."""
    if not text or not text.strip():
        return None
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        logger.warning("structured reply was not valid JSON: %r", text[:500])
        return None
    return parsed if isinstance(parsed, dict) else None


def _truthy(value) -> bool:
    """Defensive: text.format=json_object guarantees valid JSON, not that the model picked the right
    JSON *type* for a boolean field — tolerate a stray "true"/"false" string instead of treating it
    as Python's default (non-empty string) truthiness, which would misread "false" as true."""
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "sim")
    return bool(value)


def _dispatch_structured_reply(payload: dict, *, ticket_id: int, ai_department_id: int, mode: str) -> str:
    """Turns the model's structured decision into the same Rails webhook calls the old control tools
    used to trigger (Api::Internal::AiExecuteToolController) — except now PYTHON decides to call them
    because the JSON says so, not because the model chose (or "forgot") to call a tool."""
    dados = payload.get(DADOS_KEY)
    if isinstance(dados, dict):
        for chave, valor in dados.items():
            _post_control_tool(
                MEMORY_TOOL, {"chave": chave, "valor": valor},
                ticket_id=ticket_id, ai_department_id=ai_department_id, mode=mode,
            )

    if _truthy(payload.get(AVANCAR_KEY)):
        _post_control_tool(
            ADVANCE_STEP_TOOL, {}, ticket_id=ticket_id, ai_department_id=ai_department_id, mode=mode,
        )

    if _truthy(payload.get(TRANSFERIR_KEY)):
        _post_control_tool(
            TRANSFER_TOOL, {"handoff_summary": payload.get(HANDOFF_SUMMARY_KEY, "")},
            ticket_id=ticket_id, ai_department_id=ai_department_id, mode=mode,
        )
    elif _truthy(payload.get(ENCERRAR_KEY)):
        _post_control_tool(
            RESOLVE_TOOL, {}, ticket_id=ticket_id, ai_department_id=ai_department_id, mode=mode,
        )

    reply_text = str(payload.get(MENSAGEM_KEY) or "").strip()
    # Same guardrail the old _force_text_reply protected: Ai::ActionDispatcher#reply no-ops on a
    # blank reply (never sends anything) — never send literal silence to the customer.
    return reply_text or "Só um instante, já te retorno!"


def _post_control_tool(tool_name: str, arguments: dict, *, ticket_id: int, ai_department_id: int, mode: str) -> None:
    try:
        tools.execute_tool(
            ticket_id=ticket_id, ai_department_id=ai_department_id,
            tool_name=tool_name, arguments=arguments, mode=mode,
        )
    except tools.ToolExecutionError as e:
        # Never let a Rails-side persistence hiccup swallow the reply already generated for the
        # customer — that's the exact silence bug this refactor exists to kill, from a new angle.
        logger.error("ticket_id=%s: control tool webhook failed for %s: %s", ticket_id, tool_name, e)
