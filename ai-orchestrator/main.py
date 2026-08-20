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
# these (this file and orchestrator.py share the same logger name, one config covers both). Level
# comes from config.LOG_LEVEL (env var LOG_LEVEL, default INFO) — see config.py for what each level
# shows; falls back to INFO if the env var holds something that isn't a real logging level name.
logging.basicConfig(level=getattr(logging, config.LOG_LEVEL, logging.INFO),
                    format="%(asctime)s %(name)s %(levelname)s %(message)s")
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
    ai_agent_id: int
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
    # Catálogo FECHADO de nomes que "dados_coletados[].chave" pode assumir neste agente
    # (Ai::StateManager#known_slot_keys — etapas do playbook ∪ Ai::LeadVariable ∪
    # CustomAttributeDefinition da conta). orchestrator.py injeta isso como enum no schema estrito —
    # a OpenAI passa a rejeitar qualquer chave fora do catálogo, em vez de só confiar no texto do
    # prompt. [] (default) = sem restrição, mesmo comportamento de sempre.
    known_attribute_keys: list[str] = []
    # Pedido do dono da conta (19/08): texto configurado da conta que ANTES ia solto no system_prompt
    # — agora entra na description do campo correspondente do schema (orchestrator._build_reply_schema)
    # em vez de duplicado em texto. transfer_when/close_when/close_message espelham
    # Ai::PythonOrchestratorClient#transfer_when_text/#close_when_text/#close_message; collect_hint
    # espelha #step_extraction_instruction (removidos do Rails no mesmo pedido).
    transfer_when: Optional[str] = None
    close_when: Optional[str] = None
    close_message: Optional[str] = None
    collect_hint: Optional[dict] = None


class ProcessResponse(BaseModel):
    ticket_id: int
    reply: str
    conversation_id: str
    # True quando account_api_key foi passada mas falhou por auth e a chamada real caiu pra chave
    # global — Rails usa isso pra cobrar 1 crédito (Ai::Gateway#consume_byok_fallback_credit).
    byok_fallback: bool = False
    # Auto-relato do modelo (0.0-1.0, orchestrator.CONFIANCA_KEY) — None quando o parse do JSON
    # falhou. Rails (Ai::HandoffEvaluator/Ai::Gateway) decide se transfere por baixa confiança;
    # Python só reporta.
    confidence: Optional[float] = None
    # true quando ESTE turno já disparou TRANSFER_TOOL (o modelo pediu transferir_humano) — Rails usa
    # isso pra não tentar transferir de novo por baixa confiança em cima de um handoff que já rodou.
    transferred: bool = False
    # Achado ao vivo (20/08): sem isto, Ai::Run.tokens_in/tokens_out/cost ficava ZERADO pra todo turno
    # deste motor — a tela "Custos de IA" (Rails) nunca soube quanto uma conversa realmente gastou,
    # embora a OpenAI cobrasse de verdade. Soma de TODAS as chamadas reais do turno (tool loop pode
    # fazer mais de uma) — ver _run_turn/orchestrator.run_conversation.
    tokens_in: int = 0
    tokens_out: int = 0
    # Modelo REALMENTE usado (request.model, ou o fallback config.OPENAI_MODEL quando Rails não manda
    # nenhum — ver orchestrator.run_conversation#resolved_model) — Rails precisa do valor real, não do
    # que mandou, pra calcular o custo com o preço certo (o fallback pode divergir do que o tenant tem
    # configurado).
    model: str = ""


def _authenticate(authorization: Optional[str]) -> None:
    # O esquema do header Authorization é case-insensitive (RFC 7235): "bearer <token>" é tão válido
    # quanto "Bearer <token>", e o removeprefix anterior rejeitava o primeiro como não-autenticado.
    raw = (authorization or "").strip()
    token = raw[7:].strip() if raw[:7].lower() == "bearer " else raw
    if not token or not secrets.compare_digest(token, config.RAILS_INTERNAL_API_TOKEN):
        raise HTTPException(status_code=401, detail="unauthorized")


@app.post("/process", response_model=ProcessResponse)
def process(request: ProcessRequest, authorization: Optional[str] = Header(None)) -> ProcessResponse:
    _authenticate(authorization)

    # Full dump of exactly what Rails sent (system_prompt/tools_schema) — DEBUG-only (config.LOG_LEVEL):
    # useful to catch a payload building a generic/hallucinated flow instead of the configured
    # tools/knowledge, but too big to sit at INFO on every single turn (drowns the short per-turn
    # signal a human is actually scanning for). Bump LOG_LEVEL=DEBUG to bring it back when debugging.
    logger.debug(
        "ticket_id=%s ai_agent_id=%s payload received:\nsystem_prompt=%s\ntools_schema=%s\nvector_store_id=%s",
        request.ticket_id, request.ai_agent_id, request.system_prompt,
        json.dumps(request.tools_schema, ensure_ascii=False), request.vector_store_id,
    )

    try:
        reply_text, conversation_id, byok_fallback, confidence, transferred, tokens_in, tokens_out, used_model = orchestrator.run_conversation(
            ticket_id=request.ticket_id,
            ai_agent_id=request.ai_agent_id,
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
            known_attribute_keys=request.known_attribute_keys,
            transfer_when=request.transfer_when,
            close_when=request.close_when,
            close_message=request.close_message,
            collect_hint=request.collect_hint,
        )
    except orchestrator.TurnFailed as e:
        # Never leak internals (stack traces, prompts, API errors) to the Rails side — só o
        # conversation_id, que o Rails PRECISA persistir mesmo no erro: sem ele o turno seguinte
        # abriria uma conversation nova e perderia o histórico inteiro do atendimento por causa de
        # uma única chamada com falha (ver orchestrator.TurnFailed / Ai::PythonOrchestratorClient).
        logger.exception("ticket_id=%s ai_agent_id=%s: AI processing failed", request.ticket_id, request.ai_agent_id)
        raise HTTPException(status_code=502,
                            detail={"error": "AI processing failed", "conversation_id": e.conversation_id})
    except Exception:
        # Falha ANTES de existir uma conversation (ou fora do turno): não há id a preservar.
        logger.exception("ticket_id=%s ai_agent_id=%s: AI processing failed", request.ticket_id, request.ai_agent_id)
        raise HTTPException(status_code=502, detail="AI processing failed")

    # DEBUG (temporary): a blank reply here means Ai::ActionDispatcher#reply on the Rails side no-ops
    # (never sends anything) — the customer got silence. orchestrator.py now guards against this
    # (_force_text_reply), so this log is what confirms whether that guard is actually firing/working.
    logger.info("ticket_id=%s reply enviada para Rails: %s", request.ticket_id, reply_text)

    return ProcessResponse(ticket_id=request.ticket_id, reply=reply_text, conversation_id=conversation_id,
                            byok_fallback=byok_fallback, confidence=confidence, transferred=transferred,
                            tokens_in=tokens_in, tokens_out=tokens_out, model=used_model)
