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
    },
    "required": [MENSAGEM_KEY, DADOS_KEY, AVANCAR_KEY, TRANSFERIR_KEY, ENCERRAR_KEY, HANDOFF_SUMMARY_KEY],
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
# of type 'json_object'." `instructions` (system_prompt) não contava, não importa quanto falasse de
# JSON — um "Oi" sozinho como input inteiro dava 400 sempre. Migrado pra json_schema estrito
# (STRUCTURED_REPLY_SCHEMA) — não confirmado se a mesma exigência vale pra json_schema (o schema já
# força o shape, então é plausível que não precise mais), mas mantido por segurança: não faz mal
# incluir, e tirar sem confirmar reabriria o mesmo 400 se a exigência persistir. Item PRÓPRIO de
# input (não prefixado na mensagem do cliente) pra user_input chegar ao modelo — e o que a OpenAI
# guarda server-side pro previous_response_id — byte-idêntico ao que o cliente realmente digitou.
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
    actions. Always returns (reply_text, response_id, byok_fallback) — including when parsing fails
    or MAX_TOOL_ITERATIONS is hit — so the caller (main.py) never has to special-case a cut-off turn,
    only real transport/API failures.

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

    create_kwargs = {
        "model": resolved_model,
        "instructions": system_prompt,
        "input": _build_input(user_input, image_urls),
        "tools": openai_tools,
        # Responses API structured-output param — NOT "response_format" (that's the older Chat
        # Completions name; passing it here would raise a TypeError on this SDK/API instead of
        # working). json_schema ESTRITO (STRUCTURED_REPLY_SCHEMA acima) — a OpenAI valida a resposta
        # contra o schema antes de devolver, não é mais "confia que o texto do prompt basta".
        "text": _TEXT_FORMAT,
    }
    # Omitted entirely (not sent as null) when absent, so OpenAI starts a fresh conversation
    # instead of trying to resume a previous_response_id that doesn't exist, and so temperature
    # falls back to OpenAI's own default instead of us hardcoding one.
    if previous_response_id:
        create_kwargs["previous_response_id"] = previous_response_id
    if temperature is not None:
        create_kwargs["temperature"] = temperature

    # "text" incluso de propósito (achado ao vivo 13/08 — ticket_id=556: sem isto, não dava pra
    # confirmar de fora se um sandbox estava rodando json_schema estrito ou ainda json_object só
    # olhando o log). Loga create_kwargs INTEIRO menos "input" (conteúdo do cliente/histórico —
    # não precisa duplicar aqui, e cresce sem limite turno a turno).
    logger.info(
        "ticket_id=%s provider=%s model=%s create_kwargs (sem 'input'): %s",
        ticket_id, provider, resolved_model,
        json.dumps({k: v for k, v in create_kwargs.items() if k != "input"}, ensure_ascii=False),
    )

    client, using_account_key = _resolve_client(account_api_key)
    response, client, byok_fallback = _call_with_byok_fallback(client, using_account_key, ticket_id, create_kwargs)

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

            result = _normalize_tool_result(result)

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
            "text": _TEXT_FORMAT,
        }
        if temperature is not None:
            followup_kwargs["temperature"] = temperature

        response = client.responses.create(**followup_kwargs)

    payload = _parse_structured_reply(response.output_text)
    if payload is None:
        # Last-resort guardrail: either the turn cut off (MAX_TOOL_ITERATIONS) still holding a
        # function call, or the model somehow returned unparseable JSON. Chained via
        # previous_response_id (full turn history is already there) with NO tools — a function call
        # is off the table, so this call can't itself degrade into another empty/non-JSON turn.
        response = client.responses.create(
            model=resolved_model,
            previous_response_id=response.id,
            input="Responda ao cliente agora, no formato JSON definido no system prompt, com base no "
                  "que você acabou de fazer.",
            text=_TEXT_FORMAT,
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
    return reply_text, response.id, byok_fallback


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

