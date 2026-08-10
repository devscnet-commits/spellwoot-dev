import logging
import secrets
from typing import Optional

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

import config
import orchestrator

logger = logging.getLogger("ai_orchestrator")

app = FastAPI(title="AI Orchestrator")


class ProcessRequest(BaseModel):
    ticket_id: int
    system_prompt: str
    tools_schema: list = []
    vector_store_id: Optional[str] = None
    user_input: str
    previous_response_id: Optional[str] = None
    ai_department_id: int
    mode: str
    # Multi-tenant: each Rails Account picks its own model/temperature via Ai::OperationProfile.
    # Falls back to config.OPENAI_MODEL / the OpenAI default when the tenant has no profile.
    model: Optional[str] = None
    temperature: Optional[float] = None


class ProcessResponse(BaseModel):
    ticket_id: int
    reply: str
    response_id: str


def _authenticate(authorization: Optional[str]) -> None:
    token = (authorization or "").removeprefix("Bearer ").strip()
    if not token or not secrets.compare_digest(token, config.RAILS_INTERNAL_API_TOKEN):
        raise HTTPException(status_code=401, detail="unauthorized")


@app.post("/process", response_model=ProcessResponse)
def process(request: ProcessRequest, authorization: Optional[str] = Header(None)) -> ProcessResponse:
    _authenticate(authorization)

    try:
        reply_text, response_id = orchestrator.run_conversation(
            ticket_id=request.ticket_id,
            ai_department_id=request.ai_department_id,
            mode=request.mode,
            system_prompt=request.system_prompt,
            tools_schema=request.tools_schema,
            vector_store_id=request.vector_store_id,
            user_input=request.user_input,
            previous_response_id=request.previous_response_id,
            model=request.model,
            temperature=request.temperature,
        )
    except Exception:
        # Never leak internals (stack traces, prompts, API errors) to the Rails side.
        logger.exception("ticket_id=%s ai_department_id=%s: AI processing failed", request.ticket_id, request.ai_department_id)
        raise HTTPException(status_code=502, detail="AI processing failed")

    return ProcessResponse(ticket_id=request.ticket_id, reply=reply_text, response_id=response_id)
