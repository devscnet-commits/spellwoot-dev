import httpx

import config

WEBHOOK_PATH = "/api/internal/ai_execute_tool"


class ToolExecutionError(Exception):
    pass


def execute_tool(*, ticket_id: int, ai_department_id: int, tool_name: str, arguments: dict, mode: str) -> dict:
    """POSTs back to Rails so a custom (non-native) tool call runs through the existing
    Ai::ToolExecutor/Ai::CapabilityRegistry audit trail, then returns its result to the caller
    so the reasoning loop can feed it back to the OpenAI Responses API as a function_call_output."""
    payload = {
        "ticket_id": ticket_id,
        "tool_name": tool_name,
        "arguments": arguments,
        "ai_department_id": ai_department_id,
        "mode": mode,
    }
    headers = {"Authorization": f"Bearer {config.RAILS_INTERNAL_API_TOKEN}"}

    try:
        response = httpx.post(
            f"{config.RAILS_BASE_URL}{WEBHOOK_PATH}",
            json=payload,
            headers=headers,
            timeout=config.RAILS_TOOL_TIMEOUT,
        )
        response.raise_for_status()
        return response.json()
    except httpx.HTTPError as e:
        raise ToolExecutionError(f"Rails tool webhook failed for {tool_name}: {e}") from e
