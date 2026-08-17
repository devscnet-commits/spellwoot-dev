import json
import logging

from openai import AuthenticationError, OpenAI

import config
import tools

logger = logging.getLogger("ai_orchestrator")

_client = OpenAI(api_key=config.OPENAI_API_KEY)


def _resolve_client(account_api_key: str | None) -> tuple[OpenAI, bool]:
    """BYOK (billing Fase 3): a Rails account pode ter sua própria chave OpenAI configurada
    (Ai::ModelRouter.account_provider_key) — sem isto, TODA conta usava sempre a chave global fixa
    (_client acima), mesmo quando tinha a própria configurada (achado em auditoria 13/08: nenhuma
    linha deste arquivo jamais leu uma chave por-request). Retorna (client, is_account_key); a
    validação de fato só acontece na PRIMEIRA chamada real (ver _call_with_byok_fallback) — uma
    OpenAI(api_key=...) não bate na rede até o primeiro request."""
    if account_api_key:
        return OpenAI(api_key=account_api_key), True
    return _client, False


def _call_with_byok_fallback(client: OpenAI, using_account_key: bool, ticket_id: int, kwargs: dict):
    """1ª chamada real da conversa: tenta a chave da CONTA se veio uma; se falhar por auth, cai pra
    chave global da SCNET (mesma semântica do antigo Ai::Gateway#maybe_byok_fallback do caminho
    legado — chave própria falhou por auth -> retry na global -> Rails cobra 1 crédito). Devolve
    (response, client_a_usar_dali_pra_frente, byok_fallback) — chamadas SEGUINTES do MESMO turno
    (loop de tools, re-ask) devem usar o client retornado aqui, nunca voltar a tentar a chave ruim."""
    try:
        return client.responses.create(**kwargs), client, False
    except AuthenticationError:
        if not using_account_key:
            raise  # a própria chave global falhando é erro real, não BYOK — não engolir

        logger.warning("ticket_id=%s: chave própria da conta falhou por auth, caindo pra chave global", ticket_id)
        return _client.responses.create(**kwargs), _client, True


def _ensure_conversation(client: OpenAI, using_account_key: bool, ticket_id: int, conversation_id: str | None):
    """A OpenAI Conversations API exige que o objeto exista no servidor ANTES de ser referenciado num
    /v1/responses (conversation=conv_id) — diferente do antigo previous_response_id, que só apontava
    pra última resposta e nascia sozinho em toda chamada (e expirava em 30 dias, perdendo a cadeia).
    conversation_id ausente => primeiro turno do atendimento: cria uma conversation nova (persistente,
    sem expiração) e usa ela daqui em diante. Mesma semântica de fallback BYOK que
    _call_with_byok_fallback usa pras respostas: tenta a chave da conta primeiro, cai pra global se
    falhar por auth. Devolve (conversation_id, client_a_usar_dali_pra_frente, byok_fallback)."""
    if conversation_id:
        return conversation_id, client, False
    try:
        return client.conversations.create().id, client, False
    except AuthenticationError:
        if not using_account_key:
            raise

        logger.warning("ticket_id=%s: chave própria da conta falhou ao criar a conversation, caindo pra chave global", ticket_id)
        return _client.conversations.create().id, _client, True

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
# Achado ao vivo (17/08): o motor Ruby legado tinha um campo handoff_target (nome do time, casado
# contra uma whitelist — Ai::PromptCompiler#human_handoff_teams) que o Structured Outputs nunca
# reproduziu — transferir_humano virou um boolean cego, SEMPRE caindo no time padrão/configurado,
# nunca escolhido pela IA por intenção. Ai::PythonOrchestratorClient#handoff_target_instruction lista
# os times permitidos no prompt (mesma whitelist agent.handoff_team_ids); este campo é onde a IA
# devolve o nome escolhido — Api::Internal::AiExecuteToolController#transfer_to_human repassa pro
# MESMO Ai::HandoffCoordinator#human_team_id/match_team_by_name que o motor legado já usava.
HANDOFF_TARGET_KEY = "handoff_target"

# Same tool_name strings Api::Internal::AiExecuteToolController already recognizes (and already
# recognized before this refactor — see Ai::PythonOrchestratorClient::MEMORY_TOOL/ADVANCE_STEP_TOOL/
# TRANSFER_TOOL/RESOLVE_TOOL). TRANSFER_TOOL/RESOLVE_TOOL are pre-sanitized ("." -> "_",
# Ai::ToolNameSanitizer) because the controller compares against the SANITIZED name for those two.
MEMORY_TOOL = "salvar_memoria_ia"
ADVANCE_STEP_TOOL = "avancar_etapa"
TRANSFER_TOOL = "conversation_transfer"
RESOLVE_TOOL = "conversation_resolve"

# json_schema ESTRITO (não json_object livre): a OpenAI VALIDA a resposta contra este schema antes de
# devolver — "avancar_etapa": "sim" ou um "dados_coletados" com chave livre vira erro da API, não um
# JSON mal-formado que a IA podia mandar antes. dados_coletados é LISTA (não objeto {chave: valor}
# livre) porque json_schema estrito não aceita propriedades de nome arbitrário (additionalProperties
# tem que ser false em TODO nível) — a lista continua aceitando vários dados no mesmo turno, só que
# cada um é um item {chave, valor} tipado. Strict mode exige TODA propriedade em "required" (sem
# opcional de verdade) e additionalProperties:false em cada objeto, inclusive dentro de "items".
STRUCTURED_REPLY_SCHEMA = {
    "type": "object",
    "properties": {
        MENSAGEM_KEY: {"type": "string", "description": "O texto que será enviado ao cliente no WhatsApp."},
        DADOS_KEY: {
            "type": "array",
            "description": (
                "TODOS os dados que o cliente forneceu NESTA mensagem, um item por dado (nome, cidade, "
                "CPF, telefone, e-mail, preferência etc.). OBRIGATÓRIO: se a mensagem_para_cliente "
                "menciona ou reconhece um dado (ex.: 'Obrigado, Joana'), esse dado TEM que estar aqui — "
                "nunca deixe a lista vazia quando você citou o dado no texto. Lista vazia [] SÓ quando o "
                "cliente não informou nada novo neste turno."
            ),
            "items": {
                "type": "object",
                "properties": {
                    "chave": {"type": "string", "description": "Nome descritivo do dado (ex.: 'nome_completo', 'cidade')."},
                    "valor": {"type": "string", "description": "O valor exato que o cliente informou pra esse dado."},
                },
                "required": ["chave", "valor"],
                "additionalProperties": False,
            },
        },
        AVANCAR_KEY: {
            "type": "boolean",
            "description": "true quando a etapa atual estiver concluída (o dado dela já está em dados_coletados) ou o cliente recusou um dado opcional; false caso contrário.",
        },
        TRANSFERIR_KEY: {"type": "boolean", "description": "true SOMENTE quando precisar transferir para um atendente humano AGORA."},
        ENCERRAR_KEY: {"type": "boolean", "description": "true SOMENTE quando as condições de encerramento configuradas foram atendidas."},
        HANDOFF_SUMMARY_KEY: {
            "type": "string",
            "description": "Resumo do atendimento — obrigatório (não vazio) quando transferir_humano for true; string vazia nos outros casos.",
        },
        HANDOFF_TARGET_KEY: {
            "type": "string",
            "description": (
                "SÓ quando transferir_humano for true: nome EXATO do time/setor de destino, copiado da "
                "lista de times disponíveis nas instructions — nunca invente nem use uma categoria "
                "genérica. Deixe vazio (\"\") se nenhum time da lista se encaixar, ou se transferir_humano "
                "for false."
            ),
        },
    },
    "required": [MENSAGEM_KEY, DADOS_KEY, AVANCAR_KEY, TRANSFERIR_KEY, ENCERRAR_KEY, HANDOFF_SUMMARY_KEY, HANDOFF_TARGET_KEY],
    "additionalProperties": False,
}

_TEXT_FORMAT = {
    "format": {
        "type": "json_schema",
        "name": "resposta_atendimento",
        "schema": STRUCTURED_REPLY_SCHEMA,
        "strict": True,
    }
}

# No longer offered as OpenAI function tools: the model now expresses these via the JSON reply itself
# (see the keys above), not a tool call. "registrar_*" (one synthesized tool per known attribute,
# Ai::StepCaptureTool) is superseded the same way "salvar_memoria_ia" is — "dados_coletados" is a
# LIST of {chave, valor} items (ver STRUCTURED_REPLY_SCHEMA — json_schema estrito exige um shape fixo,
# não aceita objeto de chave livre), so a dedicated tool per attribute buys nothing extra. Rails
# (Ai::PythonOrchestratorClient#tools_schema) still computes and sends these — left alone there to
# keep this a Python-side contract change — so they're filtered out here before ever reaching OpenAI.
# Anything else in tools_schema (admin-configured webhooks/integrations, Ai::Tool rows) is a REAL
# action, not data collection/flow control, and stays as a normal function-calling tool.
_CONTROL_TOOL_NAMES = {"continuar_conversa", MEMORY_TOOL, ADVANCE_STEP_TOOL, TRANSFER_TOOL, RESOLVE_TOOL}
_CAPTURE_TOOL_PREFIX = "registrar_"


def _is_superseded_tool(name: str) -> bool:
    return name in _CONTROL_TOOL_NAMES or name.startswith(_CAPTURE_TOOL_PREFIX)


# OpenAI's text.format=json_object EXIGIA a palavra "json" nas mensagens de INPUT — live 400
# confirmado: "Response input messages must contain the word 'json' in some form to use 'text.format'
# of type 'json_object'." Migrado pra json_schema estrito (STRUCTURED_REPLY_SCHEMA) e pra
# instructions reenviadas em TODA chamada do turno (ver _build_instructions/run_conversation) — o
# lembrete agora vai em "instructions", nunca em "input" (input carrega só o turno real do cliente/
# ferramenta, nunca um recado da infra pro modelo).
_JSON_FORMAT_REMINDER_TEXT = (
    "Lembrete de formato: sua resposta final a este turno deve ser SEMPRE o objeto JSON "
    "definido nas instructions — nunca texto livre."
)


def _build_instructions(system_prompt: str) -> str:
    """system_prompt (persona + etapa + contrato JSON, montado pelo Rails) + o lembrete de formato,
    sempre juntos. Chamada em TODA requisição do turno (inicial, followup de tool, retry) — instrui a
    Responses API a nunca perder o contexto/contrato entre chamadas do mesmo turno."""
    return f"{system_prompt}\n\n{_JSON_FORMAT_REMINDER_TEXT}"


def _build_input(user_input: str, image_urls: list[str] | None):
    """O turno atual do cliente: texto puro, ou uma lista multimodal input_text/input_image(s) quando
    há algo pra ver neste turno — uma foto do WhatsApp, e/ou as páginas rasterizadas (base64 data
    URIs) de um documento escaneado (Ai::Workers::MediaProcessor.pending_vision_images) — assim o
    modelo lê nativamente na MESMA chamada, sem depender de uma legenda de uma chamada de visão
    separada e sem contexto (era isso que deixava uma CNH's "1997" ser lida como "1991")."""
    if not image_urls:
        return [{"role": "user", "content": user_input}]

    content = [{"type": "input_text", "text": user_input}]
    content += [{"type": "input_image", "image_url": url} for url in image_urls]
    return [{"role": "user", "content": content}]


def _normalize_tool_result(result: dict) -> dict:
    """Generalização do fix de consultar_conhecimento (knowledge_timeout/knowledge_search_failed, ver
    Api::Internal::AiExecuteToolController#search_knowledge) pra QUALQUER tool real: achado ao vivo
    (conv 556) — quando uma ferramenta real falhava, o modelo não tinha nenhum sinal confiável de que
    era um ERRO técnico (em vez de "a ferramenta rodou e não achou nada"), e travava enrolando o
    cliente. Duas formas de falha chegam aqui com shapes DIFERENTES: (a) falha de transporte
    (tools.ToolExecutionError, vira {"error": "<mensagem>"} sem "status"); (b) falha lógica que o
    Rails devolve com HTTP 200 (Ai::ToolExecutor#build -> {"result":, "status":"failed", "error":}).
    Normaliza as duas no MESMO envelope {"error": true, "message": "..."} — só quando é falha DE
    VERDADE; "skipped" (shadow, missing_required_attributes, tool inativa) fica intocado, porque ali
    "error" já é uma mensagem de dado faltando, não uma falha técnica — o modelo já sabe reagir a
    isso pedindo o dado, não avisando "problema técnico"."""
    status = result.get("status")
    if status == "failed":
        return {"error": True, "message": result.get("error") or "Falha ao executar a ferramenta."}
    if status is None and result.get("error"):
        return {"error": True, "message": result["error"]}
    return result


def _log_create_kwargs(ticket_id: int, kwargs: dict) -> None:
    """Auditoria completa (achado ao vivo: a versão anterior deste log resumia DEMAIS — só
    input_enviado/output_text_bruto, sem model/instructions/tools/text/conversation/temperature
    juntos, sem dar pra conferir de fora se strict:true continua valendo, por exemplo).
    Loga o create_kwargs INTEIRO, sempre, pra CADA chamada real (inicial, followup, retry) — nunca
    resumido. Único campo tratado diferente é "input": ele cresce turno a turno (function_call_output
    acumulado no loop de tools) e o conteúdo do cliente já é auditável via #_dispatch_structured_reply
    separadamente — aqui vira só tamanho + prévia, pra não estourar uma linha de log gigante.
    "instructions" (system_prompt inteiro) e "tools" (lista completa) NUNCA são resumidos."""
    to_log = dict(kwargs)
    input_value = to_log.get("input")
    if input_value is not None:
        raw = json.dumps(input_value, ensure_ascii=False)
        to_log["input"] = f"<{len(raw)} chars> {raw[:200]}"
    logger.info("ticket_id=%s create_kwargs_completo=%s", ticket_id, json.dumps(to_log, ensure_ascii=False))


def _log_raw_response(ticket_id: int, response) -> None:
    """Achado ao vivo (tickets 560/561/562): o log só mostrava o texto final já processado ("Reply
    enviada para Rails: ...") — reconstruir um bug exigia remontar o turno a turno via print de
    WhatsApp, em vez de ler direto do log. Loga a resposta CRUA da OpenAI (antes de qualquer parse),
    em TODA chamada do turno — inicial, followup (loop de tool calls) e o retry de último recurso.
    output_text sozinho pode não capturar tudo (ex.: parte da resposta em blocos separados tipo
    function_call + message) — loga os dois. %s deixa o logging formatar só se o nível estiver
    ativo (lazy), sem custo de serialização adiantada; str()/repr() dos objetos do SDK já é legível.
    function_calls_bruto extraído à parte (não só dentro de output_bruto) — mais fácil de escanear
    quais tools o modelo pediu nesta resposta específica, sem garimpar a lista inteira de output."""
    logger.info("ticket_id=%s response_id=%s output_text_bruto=%s", ticket_id, response.id, response.output_text)
    logger.info("ticket_id=%s response_id=%s output_bruto=%s", ticket_id, response.id, response.output)
    function_calls = [item for item in response.output if item.type == "function_call"]
    if function_calls:
        logger.info(
            "ticket_id=%s response_id=%s function_calls_bruto=%s", ticket_id, response.id,
            json.dumps([{"name": c.name, "arguments": c.arguments, "call_id": c.call_id} for c in function_calls],
                       ensure_ascii=False),
        )


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
    conversation_id: str | None,
    model: str | None = None,
    provider: str | None = None,
    temperature: float | None = None,
    image_urls: list[str] | None = None,
    account_api_key: str | None = None,
) -> tuple[str, str, bool]:
    """Owns the OpenAI Responses API turn. The model's ONLY output is the structured JSON contract
    (text.format=json_schema, strict — STRUCTURED_REPLY_SCHEMA) — control flow (save/advance/transfer/
    close) is decided by Python from the parsed JSON and dispatched to Rails' webhook, never by which
    tool the model chose to call.
    Real (admin-configured) business tools are still offered as function tools for genuine external
    actions. Always returns (reply_text, conversation_id, byok_fallback) — including when parsing
    fails or MAX_TOOL_ITERATIONS is hit — so the caller (main.py) never has to special-case a cut-off
    turn, only real transport/API failures.

    `provider` is accepted and logged ONLY — no dispatch yet: multi-provider routing doesn't exist,
    only multi-KEY (BYOK, same provider) via account_api_key.

    account_api_key: chave própria da conta (Ai::ModelRouter.account_provider_key, BYOK Fase 3),
    quando configurada. byok_fallback no retorno avisa Rails que essa chave falhou por auth e a
    chamada real caiu pra chave global — Rails usa isso pra cobrar 1 crédito (ver
    Ai::Gateway#consume_byok_fallback_credit)."""
    openai_tools = _build_tools(tools_schema, vector_store_id)
    # Multi-tenant: Rails resolves this per Account (Ai::OperationProfile); config.OPENAI_MODEL is
    # only the fallback for a tenant with no profile, never a global override.
    resolved_model = model or config.OPENAI_MODEL
    instructions = _build_instructions(system_prompt)

    client, using_account_key = _resolve_client(account_api_key)
    # A OpenAI Conversation precisa existir ANTES da primeira chamada (ver _ensure_conversation) —
    # conversation_id ausente = primeiro turno do atendimento, cria uma conversation nova.
    conversation_id, client, conv_byok_fallback = _ensure_conversation(client, using_account_key, ticket_id, conversation_id)
    using_account_key = using_account_key and not conv_byok_fallback

    create_kwargs = {
        "model": resolved_model,
        "conversation": conversation_id,
        "instructions": instructions,
        "input": _build_input(user_input, image_urls),
        "tools": openai_tools,
        # Um tool call por resposta — o modelo decide/salva/avança um passo de cada vez, nunca vários
        # de uma vez na mesma resposta.
        "parallel_tool_calls": False,
        # Responses API structured-output param — NOT "response_format" (that's the older Chat
        # Completions name; passing it here would raise a TypeError on this SDK/API instead of
        # working). json_schema ESTRITO (STRUCTURED_REPLY_SCHEMA acima) — a OpenAI valida a resposta
        # contra o schema antes de devolver, não é mais "confia que o texto do prompt basta".
        "text": _TEXT_FORMAT,
    }
    # Omitted entirely (not sent as null) when absent, so temperature falls back to OpenAI's own
    # default instead of us hardcoding one.
    if temperature is not None:
        create_kwargs["temperature"] = temperature

    logger.info("ticket_id=%s provider=%s model=%s primeira chamada do turno", ticket_id, provider, resolved_model)
    _log_create_kwargs(ticket_id, create_kwargs)

    response, client, response_byok_fallback = _call_with_byok_fallback(client, using_account_key, ticket_id, create_kwargs)
    byok_fallback = conv_byok_fallback or response_byok_fallback
    _log_raw_response(ticket_id, response)

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
            # Achado ao vivo (tickets 560/561/562): o log só mostrava a chamada HTTP genérica
            # ("POST .../ai_execute_tool HTTP/1.1 200 OK") depois do fato — não dava pra ver, sem
            # reconstruir via print de WhatsApp, QUAL tool o modelo decidiu chamar e com quais
            # argumentos, antes da execução em si.
            logger.info("ticket_id=%s tool_chamada=%s arguments=%s", ticket_id, call.name, call.arguments)
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

            result = _normalize_tool_result(result)

            # Achado ao vivo (conv 556): o retrieve da OpenAI só devolve .output de cada response —
            # o function_call_output que REALMENTE foi mandado de volta pro modelo vive no INPUT da
            # chamada seguinte, que a API não expõe via retrieve nenhum. Sem isto não dava pra saber
            # se uma tool call ficou "pendurada" porque o resultado veio vazio/erro/schema errado, sem
            # reconstruir tudo via os logs do webhook Rails (Ai::CapabilityExecution) cruzando por
            # timestamp. Loga aqui, no ponto exato que decide o que o modelo vai ler. call_id incluso
            # pra correlacionar chamadas paralelas do MESMO tool_name no mesmo turno.
            logger.info(
                "ticket_id=%s tool_resultado=%s call_id=%s resultado_bruto=%s",
                ticket_id, call.name, call.call_id, json.dumps(result, ensure_ascii=False),
            )

            tool_outputs.append({
                "type": "function_call_output",
                "call_id": call.call_id,
                "output": json.dumps(result),
            })

        followup_kwargs = {
            "model": resolved_model,
            "conversation": conversation_id,
            "instructions": instructions,
            "input": tool_outputs,
            "parallel_tool_calls": False,
            "text": _TEXT_FORMAT,
        }
        if temperature is not None:
            followup_kwargs["temperature"] = temperature

        _log_create_kwargs(ticket_id, followup_kwargs)
        response = client.responses.create(**followup_kwargs)
        _log_raw_response(ticket_id, response)

    payload = _parse_structured_reply(response.output_text)
    if payload is None:
        # Last-resort guardrail: either the turn cut off (MAX_TOOL_ITERATIONS) still holding a
        # function call, or the model somehow returned unparseable JSON. Same conversation (full turn
        # history is already there) with NO tools — a function call is off the table, so this call
        # can't itself degrade into another empty/non-JSON turn.
        retry_kwargs = {
            "model": resolved_model,
            "conversation": conversation_id,
            "instructions": instructions,
            "input": "Responda ao cliente agora, no formato JSON definido no system prompt, com base no "
                     "que você acabou de fazer.",
            "parallel_tool_calls": False,
            "text": _TEXT_FORMAT,
        }
        if temperature is not None:
            retry_kwargs["temperature"] = temperature

        _log_create_kwargs(ticket_id, retry_kwargs)
        response = client.responses.create(**retry_kwargs)
        _log_raw_response(ticket_id, response)  # mesma categoria do followup — outra chamada no MESMO turno
        payload = _parse_structured_reply(response.output_text)

    if payload is None:
        logger.warning(
            "ticket_id=%s response_id=%s: structured reply parsing failed twice; using the static fallback",
            ticket_id, response.id,
        )
        payload = {}

    reply_text = _dispatch_structured_reply(
        payload, ticket_id=ticket_id, ai_department_id=ai_department_id, mode=mode,
    )
    return reply_text, conversation_id, byok_fallback


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
    """Defensive: mesmo com json_schema estrito ("type": "boolean" em STRUCTURED_REPLY_SCHEMA) validando
    o tipo, mantido como segunda camada — tolerate a stray "true"/"false" string instead of treating it
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
    # LISTA de {chave, valor} (STRUCTURED_REPLY_SCHEMA, json_schema estrito) — não mais o objeto de
    # chave livre {chave: valor} do json_object solto; strict mode não aceita additionalProperties.
    dados = payload.get(DADOS_KEY)
    if isinstance(dados, list):
        for item in dados:
            if not isinstance(item, dict):
                continue
            chave = item.get("chave")
            if not chave:
                continue
            _post_control_tool(
                MEMORY_TOOL, {"chave": chave, "valor": item.get("valor")},
                ticket_id=ticket_id, ai_department_id=ai_department_id, mode=mode,
            )

    if _truthy(payload.get(AVANCAR_KEY)):
        _post_control_tool(
            ADVANCE_STEP_TOOL, {}, ticket_id=ticket_id, ai_department_id=ai_department_id, mode=mode,
        )

    if _truthy(payload.get(TRANSFERIR_KEY)):
        _post_control_tool(
            TRANSFER_TOOL,
            {"handoff_summary": payload.get(HANDOFF_SUMMARY_KEY, ""), "handoff_target": payload.get(HANDOFF_TARGET_KEY, "")},
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

