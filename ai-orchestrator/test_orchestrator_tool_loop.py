import json
from types import SimpleNamespace
from unittest.mock import patch

import orchestrator

# Primeiro teste automatizado deste microserviço (nenhum existia até aqui — a série "tool +
# followup" removida de spec/services/ai/gateway_spec.rb testava o LOOP ANTIGO, do lado Ruby;
# desde a eliminação do motor legado, o loop de function-calling vive inteiro aqui dentro
# (run_conversation: MAX_TOOL_ITERATIONS + previous_response_id chaining), sem nenhuma rede de
# segurança automatizada — só verificação manual ao vivo durante a sessão. Não exaustivo (não
# cobre BYOK/erro/limite de iterações): só prova que o mecanismo central — 2 idas-e-voltas de
# ferramenta encadeadas por previous_response_id dentro do MESMO turno — funciona de ponta a ponta.


def _function_call(name, arguments, call_id):
    return SimpleNamespace(type="function_call", name=name, arguments=json.dumps(arguments), call_id=call_id)


def _response(response_id, output, output_text=""):
    return SimpleNamespace(id=response_id, output=output, output_text=output_text)


def test_run_conversation_loops_through_two_sequential_tool_calls_before_replying():
    resp1 = _response("resp_1", [_function_call("consultar_conhecimento", {"pergunta": "qual o preço?"}, "call_1")])
    resp2 = _response("resp_2", [_function_call("registrar_nome", {"valor": "Joana"}, "call_2")])
    final_payload = {
        "mensagem_para_cliente": "Show, Joana! O plano custa R$ 99,90.",
        "dados_coletados": [],
        "avancar_etapa": False,
        "transferir_humano": False,
        "encerrar_atendimento": False,
        "handoff_summary": "",
    }
    resp3 = _response("resp_3", [], output_text=json.dumps(final_payload))

    with patch.object(orchestrator, "_client") as mock_client, \
         patch.object(orchestrator.tools, "execute_tool") as mock_execute_tool:
        mock_client.responses.create.side_effect = [resp1, resp2, resp3]
        mock_execute_tool.return_value = {"result": "ok"}

        reply_text, response_id, byok_fallback = orchestrator.run_conversation(
            ticket_id=1,
            ai_department_id=1,
            mode="live",
            system_prompt="system prompt de teste",
            tools_schema=[],
            vector_store_id=None,
            user_input="quanto custa e meu nome é Joana",
            previous_response_id=None,
        )

    # 3 chamadas à Responses API: a inicial + 1 followup por rodada de ferramenta (2 rodadas).
    assert mock_client.responses.create.call_count == 3
    # cada followup foi encadeado pelo previous_response_id da resposta ANTERIOR — é isso que faz
    # da 2ª chamada de ferramenta parte do MESMO turno, não uma conversa nova.
    assert mock_client.responses.create.call_args_list[1].kwargs["previous_response_id"] == "resp_1"
    assert mock_client.responses.create.call_args_list[2].kwargs["previous_response_id"] == "resp_2"

    # as 2 ferramentas foram de fato executadas (webhook Rails), na ordem certa, cada uma na sua rodada.
    assert mock_execute_tool.call_count == 2
    assert mock_execute_tool.call_args_list[0].kwargs["tool_name"] == "consultar_conhecimento"
    assert mock_execute_tool.call_args_list[1].kwargs["tool_name"] == "registrar_nome"

    # a resposta final só sai DEPOIS das 2 rodadas, com o texto estruturado corretamente despachado.
    assert reply_text == "Show, Joana! O plano custa R$ 99,90."
    assert response_id == "resp_3"
    assert byok_fallback is False
