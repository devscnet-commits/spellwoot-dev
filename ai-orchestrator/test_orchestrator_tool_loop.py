import json
from types import SimpleNamespace
from unittest.mock import patch

import orchestrator

# Primeiro teste automatizado deste microserviço (nenhum existia até aqui — a série "tool +
# followup" removida de spec/services/ai/gateway_spec.rb testava o LOOP ANTIGO, do lado Ruby;
# desde a eliminação do motor legado, o loop de function-calling vive inteiro aqui dentro
# (run_conversation: MAX_TOOL_ITERATIONS + OpenAI Conversations API), sem nenhuma rede de
# segurança automatizada — só verificação manual ao vivo durante a sessão. Não exaustivo (não
# cobre BYOK/erro/limite de iterações): só prova que o mecanismo central — 2 idas-e-voltas de
# ferramenta dentro da MESMA conversation, no MESMO turno — funciona de ponta a ponta.


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
        "confianca": 0.9,
    }
    resp3 = _response("resp_3", [], output_text=json.dumps(final_payload))

    with patch.object(orchestrator, "_client") as mock_client, \
         patch.object(orchestrator.tools, "execute_tool") as mock_execute_tool:
        mock_client.conversations.create.return_value = SimpleNamespace(id="conv_abc")
        mock_client.responses.create.side_effect = [resp1, resp2, resp3]
        mock_execute_tool.return_value = {"result": "ok"}

        reply_text, conversation_id, byok_fallback, confidence, transferred = orchestrator.run_conversation(
            ticket_id=1,
            ai_department_id=1,
            mode="live",
            system_prompt="system prompt de teste",
            tools_schema=[],
            vector_store_id=None,
            user_input="quanto custa e meu nome é Joana",
            conversation_id=None,
        )

    # conversation_id ausente => cria uma conversation nova antes da 1ª chamada.
    assert mock_client.conversations.create.call_count == 1
    # 3 chamadas à Responses API: a inicial + 1 followup por rodada de ferramenta (2 rodadas).
    assert mock_client.responses.create.call_count == 3
    # as 3 chamadas referenciam a MESMA conversation — é isso que faz da 2ª chamada de ferramenta
    # parte do MESMO turno/atendimento, sem depender de encadear por ID de resposta.
    assert mock_client.responses.create.call_args_list[0].kwargs["conversation"] == "conv_abc"
    assert mock_client.responses.create.call_args_list[1].kwargs["conversation"] == "conv_abc"
    assert mock_client.responses.create.call_args_list[2].kwargs["conversation"] == "conv_abc"
    # parallel_tool_calls=False em TODA chamada do turno — o modelo decide/salva/avança um passo de
    # cada vez, nunca vários tool calls na mesma resposta.
    for call in mock_client.responses.create.call_args_list:
        assert call.kwargs["parallel_tool_calls"] is False

    # as 2 ferramentas foram de fato executadas (webhook Rails), na ordem certa, cada uma na sua rodada.
    assert mock_execute_tool.call_count == 2
    assert mock_execute_tool.call_args_list[0].kwargs["tool_name"] == "consultar_conhecimento"
    assert mock_execute_tool.call_args_list[1].kwargs["tool_name"] == "registrar_nome"

    # a resposta final só sai DEPOIS das 2 rodadas, com o texto estruturado corretamente despachado.
    assert reply_text == "Show, Joana! O plano custa R$ 99,90."
    assert conversation_id == "conv_abc"
    assert byok_fallback is False
    assert confidence == 0.9
    assert transferred is False


# Generalização do fix de consultar_conhecimento (knowledge_timeout/knowledge_search_failed) pra
# QUALQUER tool real: achado ao vivo (conv 556, consultar_periodos) — sem isto, uma falha real de
# ferramenta não tinha nenhum sinal confiável pro modelo, que travava enrolando o cliente.
class TestNormalizeToolResult:
    def test_falha_logica_do_rails_vira_envelope_de_erro(self):
        rails_result = {"result": {}, "status": "failed", "error": "timeout no webhook externo"}

        assert orchestrator._normalize_tool_result(rails_result) == {
            "error": True,
            "message": "timeout no webhook externo",
        }

    def test_falha_de_transporte_sem_status_tambem_vira_envelope_de_erro(self):
        # shape que orchestrator.py monta no except tools.ToolExecutionError (sem "status" nenhum)
        transport_failure = {"error": "Rails tool webhook failed for consultar_periodos: 404"}

        assert orchestrator._normalize_tool_result(transport_failure) == {
            "error": True,
            "message": "Rails tool webhook failed for consultar_periodos: 404",
        }

    def test_sucesso_passa_intocado(self):
        success = {"result": {"periodos": ["manhã", "tarde"]}, "status": "executed", "error": None}

        assert orchestrator._normalize_tool_result(success) == success

    # "skipped" (shadow, missing_required_attributes, tool inativa) NÃO é falha técnica — o "error"
    # ali já é uma mensagem de dado faltando que o modelo deve usar pra pedir o dado, não pra avisar
    # "problema técnico". Envelopar isso também confundiria o modelo do jeito oposto.
    def test_skipped_com_mensagem_nao_vira_envelope_de_erro(self):
        skipped = {"result": {}, "status": "skipped",
                   "error": "Faltam os dados obrigatórios antes de usar esta ferramenta: cidade"}

        assert orchestrator._normalize_tool_result(skipped) == skipped

    def test_loop_real_normaliza_falha_antes_de_montar_o_function_call_output(self):
        resp1 = _response("resp_1", [_function_call("consultar_periodos", {"cidade": "Maravilha"}, "call_1")])
        final_payload = {
            "mensagem_para_cliente": "Tive um problema técnico agora, já vou te transferir.",
            "dados_coletados": [], "avancar_etapa": False, "transferir_humano": True,
            "encerrar_atendimento": False, "handoff_summary": "Falha técnica em consultar_periodos.",
        }
        resp2 = _response("resp_2", [], output_text=json.dumps(final_payload))

        with patch.object(orchestrator, "_client") as mock_client, \
             patch.object(orchestrator.tools, "execute_tool") as mock_execute_tool:
            mock_client.conversations.create.return_value = SimpleNamespace(id="conv_abc")
            mock_client.responses.create.side_effect = [resp1, resp2]
            mock_execute_tool.return_value = {"result": {}, "status": "failed", "error": "404 token not found"}

            orchestrator.run_conversation(
                ticket_id=1, ai_department_id=1, mode="live", system_prompt="system prompt de teste",
                tools_schema=[], vector_store_id=None, user_input="quero agendar em Maravilha",
                conversation_id=None,
            )

        # input não carrega mais o lembrete de formato (foi pra "instructions") — o único item é o
        # function_call_output da ferramenta.
        sent_output = json.loads(mock_client.responses.create.call_args_list[1].kwargs["input"][0]["output"])
        assert sent_output == {"error": True, "message": "404 token not found"}


# Cenário B1 (bug ticket 557, achado 13/08) — separa "o modelo PEDIU o avanço" de "o sistema
# APLICOU o avanço". B2 (o backend Rails recusa aplicar quando falta dado) fica em
# spec/requests/api/internal/ai_execute_tool_controller_spec.rb. Aqui, do lado Python: confirma que
# _dispatch_structured_reply SEMPRE repassa o pedido do modelo pro webhook Rails quando
# avancar_etapa:true, sem NENHUMA gate própria — orchestrator.py não tem (e não deveria ter)
# visibilidade sobre ai_collected_facts/step requirements; quem decide aplicar ou não é o Rails.
class TestAvancarEtapaSempreRepassado:
    def test_avancar_etapa_true_sempre_dispara_o_control_tool_independente_do_que_o_webhook_devolve(self):
        payload = {
            "mensagem_para_cliente": "Perfeito!",
            "dados_coletados": [], "avancar_etapa": True, "transferir_humano": False,
            "encerrar_atendimento": False, "handoff_summary": "",
        }

        with patch.object(orchestrator.tools, "execute_tool") as mock_execute_tool:
            # mesmo que o Rails devolva "recusado" (o que o patch de verdade vai fazer), Python não
            # inspeciona esse retorno pra decidir mais nada — só dispara e segue.
            mock_execute_tool.return_value = {"result": {}, "status": "blocked_missing_data", "error": None}

            reply_text, confidence, transferred = orchestrator._dispatch_structured_reply(
                payload, ticket_id=1, ai_department_id=1, mode="live",
            )

        mock_execute_tool.assert_any_call(
            ticket_id=1, ai_department_id=1, tool_name=orchestrator.ADVANCE_STEP_TOOL,
            arguments={}, mode="live",
        )
        assert reply_text == "Perfeito!"
        assert confidence is None
        assert transferred is False


# Achado ao vivo (17/08): o motor Ruby legado deixava a IA nomear o TIME de destino do handoff
# (handoff_target, casado contra whitelist) — o Structured Outputs nunca reproduziu isso, então
# transferir_humano sempre caía no time padrão, cego à intenção. handoff_target volta a existir no
# contrato JSON e precisa chegar ao control tool TRANSFER_TOOL igual ao handoff_summary.
class TestHandoffTarget:
    def test_transferir_humano_repassa_handoff_target_pro_control_tool(self):
        payload = {
            "mensagem_para_cliente": "Já vou te transferir para o Financeiro.",
            "dados_coletados": [], "avancar_etapa": False, "transferir_humano": True,
            "encerrar_atendimento": False, "handoff_summary": "Cliente quer negociar dívida.",
            "handoff_target": "Financeiro",
        }

        with patch.object(orchestrator.tools, "execute_tool") as mock_execute_tool:
            mock_execute_tool.return_value = {"result": {}, "status": "executed", "error": None}

            orchestrator._dispatch_structured_reply(payload, ticket_id=1, ai_department_id=1, mode="live")

        mock_execute_tool.assert_any_call(
            ticket_id=1, ai_department_id=1, tool_name=orchestrator.TRANSFER_TOOL,
            arguments={"handoff_summary": "Cliente quer negociar dívida.", "handoff_target": "Financeiro"},
            mode="live",
        )

    def test_handoff_target_ausente_vira_string_vazia_nunca_quebra(self):
        payload = {
            "mensagem_para_cliente": "Vou te transferir.",
            "dados_coletados": [], "avancar_etapa": False, "transferir_humano": True,
            "encerrar_atendimento": False, "handoff_summary": "Motivo.",
        }

        with patch.object(orchestrator.tools, "execute_tool") as mock_execute_tool:
            mock_execute_tool.return_value = {"result": {}, "status": "executed", "error": None}

            orchestrator._dispatch_structured_reply(payload, ticket_id=1, ai_department_id=1, mode="live")

        mock_execute_tool.assert_any_call(
            ticket_id=1, ai_department_id=1, tool_name=orchestrator.TRANSFER_TOOL,
            arguments={"handoff_summary": "Motivo.", "handoff_target": ""},
            mode="live",
        )


# Migração da confiança pro motor Python (Ai::HandoffEvaluator/department.transfer_rules
# ['min_confidence'] nunca tinha equivalente no Structured Outputs — o campo existia na tela e não
# fazia nada). Python só REPORTA "confianca"; quem decide transferir por baixa confiança é o Rails
# (Ai::Gateway), depois deste turno já ter rodado — ver orchestrator.CONFIANCA_KEY.
class TestConfianca:
    def _payload(self, **overrides):
        base = {
            "mensagem_para_cliente": "Ok!",
            "dados_coletados": [], "avancar_etapa": False, "transferir_humano": False,
            "encerrar_atendimento": False, "handoff_summary": "",
        }
        base.update(overrides)
        return base

    def test_confianca_numerica_e_repassada_ao_caller(self):
        with patch.object(orchestrator.tools, "execute_tool"):
            _, confidence, _ = orchestrator._dispatch_structured_reply(
                self._payload(confianca=0.35), ticket_id=1, ai_department_id=1, mode="live",
            )

        assert confidence == 0.35

    def test_confianca_ausente_vira_none_nunca_quebra(self):
        with patch.object(orchestrator.tools, "execute_tool"):
            _, confidence, _ = orchestrator._dispatch_structured_reply(
                self._payload(), ticket_id=1, ai_department_id=1, mode="live",
            )

        assert confidence is None

    # bool é subclasse de int em Python — sem esta exclusão explícita, um "confianca": true perdido
    # (bug do modelo/parse) viraria confidence=1 (True == 1) em vez de None, escapando do gate de
    # baixa confiança do lado Rails por acidente.
    def test_confianca_booleana_e_tratada_como_ausente(self):
        with patch.object(orchestrator.tools, "execute_tool"):
            _, confidence, _ = orchestrator._dispatch_structured_reply(
                self._payload(confianca=True), ticket_id=1, ai_department_id=1, mode="live",
            )

        assert confidence is None

    def test_transferred_reflete_transferir_humano(self):
        with patch.object(orchestrator.tools, "execute_tool"):
            _, _, transferred_true = orchestrator._dispatch_structured_reply(
                self._payload(transferir_humano=True, handoff_summary="motivo"),
                ticket_id=1, ai_department_id=1, mode="live",
            )
            _, _, transferred_false = orchestrator._dispatch_structured_reply(
                self._payload(), ticket_id=1, ai_department_id=1, mode="live",
            )

        assert transferred_true is True
        assert transferred_false is False
