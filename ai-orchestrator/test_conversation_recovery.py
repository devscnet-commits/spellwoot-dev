import json
from types import SimpleNamespace
from unittest.mock import patch

import httpx
import pytest
from openai import NotFoundError

import orchestrator

# Recuperação de conversation órfã: um conv_... pertence à ORGANIZAÇÃO da chave que o criou, então
# toda troca de chave efetiva de uma conta (cliente cadastrou/rotacionou a própria chave, BYOK
# ligado/desligado, camada global do Hub aposentada, chave da plataforma girada) deixa o id guardado
# no Rails apontando para um objeto de outra org. A OpenAI responde 404/403 — que NÃO é
# AuthenticationError e por isso nunca caiu no fallback BYOK: o turno virava 502 e o cliente ficava
# sem resposta. Ver orchestrator.CONVERSATION_ACCESS_ERRORS.

REPLY_PAYLOAD = {
    "mensagem_para_cliente": "Claro, posso ajudar!",
    "dados_coletados": [],
    "avancar_etapa": False,
    "transferir_humano": False,
    "encerrar_atendimento": False,
    "handoff_summary": "",
    "confianca": 0.9,
}


def _conversation_not_found():
    request = httpx.Request("POST", "https://api.openai.com/v1/responses")
    return NotFoundError("Conversation not found", response=httpx.Response(404, request=request), body=None)


def _reply_response():
    return SimpleNamespace(id="resp_1", output=[], output_text=json.dumps(REPLY_PAYLOAD),
                           usage=SimpleNamespace(input_tokens=10, output_tokens=5))


def _run(conversation_id):
    return orchestrator.run_conversation(
        ticket_id=1, account_id=42, ai_agent_id=1, mode="live", system_prompt="p",
        tools_schema=[], vector_store_id=None, user_input="oi", conversation_id=conversation_id,
    )


def test_conversation_herdada_de_outra_chave_recomeca_em_vez_de_falhar():
    with patch.object(orchestrator, "_client") as mock_client, \
         patch.object(orchestrator.tools, "execute_tool"):
        mock_client.conversations.create.return_value = SimpleNamespace(id="conv_nova")
        mock_client.responses.create.side_effect = [_conversation_not_found(), _reply_response()]

        reply_text, conversation_id, *_ = _run("conv_de_outra_chave")

    # O turno foi ENTREGUE (não virou 502) numa conversation nova, e é esse id que volta pro Rails —
    # sem isso o turno seguinte tentaria de novo a conversation órfã, a cada mensagem, para sempre.
    assert reply_text == REPLY_PAYLOAD["mensagem_para_cliente"]
    assert conversation_id == "conv_nova"
    assert mock_client.conversations.create.call_count == 1


def test_conversation_criada_neste_turno_nao_e_retentada():
    # Sem conversation herdada, um 404 é outra coisa (modelo inexistente, por exemplo) — criar outra
    # conversation não resolveria e só gastaria uma chamada a mais escondendo o erro real.
    with patch.object(orchestrator, "_client") as mock_client, \
         patch.object(orchestrator.tools, "execute_tool"):
        mock_client.conversations.create.return_value = SimpleNamespace(id="conv_nova")
        mock_client.responses.create.side_effect = _conversation_not_found()

        with pytest.raises(orchestrator.TurnFailed):
            _run(None)

        assert mock_client.conversations.create.call_count == 1
