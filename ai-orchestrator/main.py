import json
import logging
import secrets
from typing import Optional

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

import config
import orchestrator

# uvicorn doesn't attach a handler to the root logger by default, so a plain getLogger(...).info()
# would silently go nowhere — basicConfig gives it a stdout handler so `docker logs` actually shows
# these (this file and orchestrator.py share the same logger name, one config covers both).
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("ai_orchestrator")

app = FastAPI(title="AI Orchestrator")


class ProcessRequest(BaseModel):
    ticket_id: int
    system_prompt: str
    tools_schema: list = []
    vector_store_id: Optional[str] = None
    user_input: str
    # OpenAI Conversations API id (conv_...), persistente e sem expiração — substitui o antigo
    # previous_response_id. None no primeiro turno do atendimento (orchestrator.py cria a conversation).
    conversation_id: Optional[str] = None
    ai_department_id: int
    mode: str
    # Multi-tenant: each Rails Account picks its own model/temperature via Ai::OperationProfile.
    # Falls back to config.OPENAI_MODEL / the OpenAI default when the tenant has no profile.
    model: Optional[str] = None
    # Trafega desde já (logado em run_conversation) mas NÃO dispatcha ainda — orchestrator.py segue
    # com um único client OpenAI fixo. Plumbing só, primeiro passo antes do dispatch real por provider.
    provider: Optional[str] = None
    temperature: Optional[float] = None
    # Raw pixels the model reads NATIVELY instead of relying on a separate, context-blind captioning
    # call: the WhatsApp photo's own URL (Rails' Attachment#download_url), and/or base64 data URIs for
    # a scanned-document PDF's rasterized pages (Ai::Workers::MediaProcessor.pending_vision_images —
    # CNH/RG/comprovante). Empty list when there's nothing to see this turn.
    image_urls: list[str] = []
    # BYOK (billing Fase 3, Ai::ModelRouter.account_provider_key): chave OpenAI própria da conta,
    # quando configurada. None = usa a chave global fixa (comportamento de sempre).
    account_api_key: Optional[str] = None


class ProcessResponse(BaseModel):
    ticket_id: int
    reply: str
    conversation_id: str
    # True quando account_api_key foi passada mas falhou por auth e a chamada real caiu pra chave
    # global — Rails usa isso pra cobrar 1 crédito (Ai::Gateway#consume_byok_fallback_credit).
    byok_fallback: bool = False


def _authenticate(authorization: Optional[str]) -> None:
    token = (authorization or "").removeprefix("Bearer ").strip()
    if not token or not secrets.compare_digest(token, config.RAILS_INTERNAL_API_TOKEN):
        raise HTTPException(status_code=401, detail="unauthorized")


@app.post("/process", response_model=ProcessResponse)
def process(request: ProcessRequest, authorization: Optional[str] = Header(None)) -> ProcessResponse:
    _authenticate(authorization)

    # DEBUG (temporary): dump exactly what Rails sent, to catch a payload that's building a
    # generic/hallucinated flow instead of using the configured tools/knowledge — remove once
    # the tools-not-firing issue is confirmed fixed.
    logger.info(
        "ticket_id=%s ai_department_id=%s payload received:\nsystem_prompt=%s\ntools_schema=%s\nvector_store_id=%s",
        request.ticket_id, request.ai_department_id, request.system_prompt,
        json.dumps(request.tools_schema, ensure_ascii=False), request.vector_store_id,
    )

    try:
        reply_text, conversation_id, byok_fallback = orchestrator.run_conversation(
            ticket_id=request.ticket_id,
            ai_department_id=request.ai_department_id,
            mode=request.mode,
            system_prompt=request.system_prompt,
            tools_schema=request.tools_schema,
            vector_store_id=request.vector_store_id,
            user_input=request.user_input,
            conversation_id=request.conversation_id,
            model=request.model,
            provider=request.provider,
            temperature=request.temperature,
            image_urls=request.image_urls,
            account_api_key=request.account_api_key,
        )
    except Exception:
        # Never leak internals (stack traces, prompts, API errors) to the Rails side.
        logger.exception("ticket_id=%s ai_department_id=%s: AI processing failed", request.ticket_id, request.ai_department_id)
        raise HTTPException(status_code=502, detail="AI processing failed")

    # DEBUG (temporary): a blank reply here means Ai::ActionDispatcher#reply on the Rails side no-ops
    # (never sends anything) — the customer got silence. orchestrator.py now guards against this
    # (_force_text_reply), so this log is what confirms whether that guard is actually firing/working.
    logger.info(f"Reply enviada para Rails: {reply_text}")

    return ProcessResponse(ticket_id=request.ticket_id, reply=reply_text, conversation_id=conversation_id,
                            byok_fallback=byok_fallback)
