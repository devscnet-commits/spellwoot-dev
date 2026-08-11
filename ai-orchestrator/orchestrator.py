import json
import logging

from openai import OpenAI

import config
import tools

logger = logging.getLogger("ai_orchestrator")

_client = OpenAI(api_key=config.OPENAI_API_KEY)


def _build_input(user_input: str, image_url: str | None):
    """Plain string when there's no image (unchanged shape); a multimodal content list — the
    Responses API's input_text/input_image parts — when the customer sent a WhatsApp photo, so the
    model's own vision reads the actual image instead of relying only on the Rails-side caption
    worker (Ai::Workers::MediaProcessor) that already folded a text description into user_input."""
    if not image_url:
        return user_input

    return [{
        "role": "user",
        "content": [
            {"type": "input_text", "text": user_input},
            {"type": "input_image", "image_url": image_url},
        ],
    }]


def _build_tools(tools_schema: list, vector_store_id: str | None) -> list:
    openai_tools = []
    if vector_store_id:
        openai_tools.append({"type": "file_search", "vector_store_ids": [vector_store_id]})

    for tool in tools_schema:
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
    image_url: str | None = None,
) -> tuple[str, str]:
    """Owns the OpenAI Responses API reasoning/tool-call loop for one turn. Always returns
    (reply_text, response_id) — including when MAX_TOOL_ITERATIONS is hit — so the caller
    (main.py) never has to special-case a cut-off loop, only real transport/API failures."""
    openai_tools = _build_tools(tools_schema, vector_store_id)
    # Multi-tenant: Rails resolves this per Account (Ai::OperationProfile); config.OPENAI_MODEL is
    # only the fallback for a tenant with no profile, never a global override.
    resolved_model = model or config.OPENAI_MODEL

    # DEBUG (temporary): confirm what actually reaches responses.create — same investigation as the
    # payload dump in main.py, this is the OTHER end (post-translation from tools_schema).
    logger.info(
        "ticket_id=%s model=%s tools sent to OpenAI: %s",
        ticket_id, resolved_model, json.dumps(openai_tools, ensure_ascii=False),
    )

    create_kwargs = {
        "model": resolved_model,
        "instructions": system_prompt,
        "input": _build_input(user_input, image_url),
        "tools": openai_tools,
    }
    # Live bug: the model replied with text-only confirmation loops ("é vendas mesmo?") and never
    # called any tool, so Rails never advanced ai_step_index. tool_choice="required" forces at least
    # one function call on THIS (first) call of the turn — never text-only. Safe to force unconditionally
    # because Rails always includes "continuar_conversa" (Ai::PythonOrchestratorClient::CONTINUE_TOOL)
    # in tools_schema, a genuine no-op the model can call when it only wants to talk — without it,
    # forcing a call here would push the model to misuse a real tool (advance early, save garbage) on
    # any turn with nothing to actually save. Only on the FIRST call: the followup call below (after
    # tool results are fed back) doesn't resend "tools" at all, so there's nothing to require there —
    # and forcing a SECOND mandatory call right after the model already acted would just invite it to
    # call something pointless a second time instead of finally replying in text.
    if openai_tools:
        create_kwargs["tool_choice"] = "required"
    # Omitted entirely (not sent as null) when absent, so OpenAI starts a fresh conversation
    # instead of trying to resume a previous_response_id that doesn't exist, and so temperature
    # falls back to OpenAI's own default instead of us hardcoding one.
    if previous_response_id:
        create_kwargs["previous_response_id"] = previous_response_id
    if temperature is not None:
        create_kwargs["temperature"] = temperature

    response = _client.responses.create(**create_kwargs)

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
            "input": tool_outputs,
        }
        if temperature is not None:
            followup_kwargs["temperature"] = temperature

        response = _client.responses.create(**followup_kwargs)

    # Live bug: tool_choice="required" (above) forces the FIRST call to be tool-call-only (no text
    # alongside a forced call), and the follow-up call right after feeding tool_outputs back sometimes
    # ALSO comes back with no visible text — the model considers the turn "done" once it has acted,
    # without a word to the customer. Rails' Ai::ActionDispatcher#reply no-ops on a blank reply (never
    # sends anything), so the customer got silence — which then looked "unanswered" to the separate
    # follow-up feature, which fired its own configured nudge message unrelated to this bug. Applies to
    # BOTH loop exits: the natural "no more function_calls" break above, and MAX_TOOL_ITERATIONS
    # exhausted below (same gap, same fix).
    reply_text = response.output_text or ""
    if not reply_text.strip():
        reply_text, response_id = _force_text_reply(
            previous_response_id=response.id, model=resolved_model, temperature=temperature,
        )
        return reply_text, response_id

    return reply_text, response.id


def _force_text_reply(*, previous_response_id: str, model: str, temperature: float | None) -> tuple[str, str]:
    """Last-resort guardrail: the tool-calling loop finished (or was cut off) with zero visible text.
    Chained via previous_response_id (full turn history + tool results are already there) and with NO
    tools/tool_choice — text is the only possible output, so this call can't itself degrade into
    another empty function-call turn. Explicitly asks the model to say something to the customer now."""
    kwargs = {
        "model": model,
        "previous_response_id": previous_response_id,
        "input": "Responda ao cliente agora, em texto, com base no que você acabou de fazer.",
    }
    if temperature is not None:
        kwargs["temperature"] = temperature

    response = _client.responses.create(**kwargs)
    reply_text = response.output_text or ""
    if not reply_text.strip():
        # Should be unreachable (no tools = the model has nothing else it CAN do but reply in text),
        # but Ai::ActionDispatcher#reply silently drops a blank reply — never send literal silence.
        logger.warning(
            "response_id=%s: _force_text_reply ALSO came back empty; using the static fallback",
            response.id,
        )
        return "Só um instante, já te retorno!", response.id

    return reply_text, response.id
