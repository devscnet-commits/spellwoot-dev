import json
import logging

from openai import OpenAI

import config
import tools

logger = logging.getLogger("ai_orchestrator")

_client = OpenAI(api_key=config.OPENAI_API_KEY)


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
        "input": user_input,
        "tools": openai_tools,
    }
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
            return response.output_text or "", response.id

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

    # MAX_TOOL_ITERATIONS exceeded: still return the latest response_id (so history keeps
    # chaining next turn) even if there's no final text yet.
    return response.output_text or "", response.id
