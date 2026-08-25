import orchestrator

# Pedido do dono da conta (19/08): transfer_when/close_when/close_message/collect_hint saíram do
# system_prompt (Rails) e passaram a entrar na description do campo correspondente do schema,
# montado por chamada (_build_reply_schema) em vez de um dict fixo carregado uma vez só. Estes
# testes provam a montagem isolada, sem precisar de um turno inteiro (ver test_orchestrator_tool_loop.py).


def _descriptions(schema):
    props = schema["properties"]
    return {
        "transferir_humano": props[orchestrator.TRANSFERIR_KEY]["description"],
        "encerrar_atendimento": props[orchestrator.ENCERRAR_KEY]["description"],
        "dados_coletados": props[orchestrator.DADOS_KEY]["description"],
    }


def test_sem_nenhum_valor_dinamico_usa_so_a_description_generica():
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when=None, close_message=None, collect_hint=None,
        known_attribute_keys=None,
    )
    desc = _descriptions(schema)

    assert desc["transferir_humano"] == "true SOMENTE quando precisar transferir para um atendente humano AGORA."
    assert "mantenha SEMPRE false" in desc["encerrar_atendimento"]
    assert "NUNCA marque true por conta própria" in desc["encerrar_atendimento"]


def test_transfer_when_configurado_entra_na_description_de_transferir_humano():
    schema = orchestrator._build_reply_schema(
        transfer_when="cliente pede humano; assunto fora do escopo", close_when=None,
        close_message=None, collect_hint=None, known_attribute_keys=None,
    )
    desc = _descriptions(schema)

    assert "Transfira quando: cliente pede humano; assunto fora do escopo." in desc["transferir_humano"]


# Achado ao vivo (17/08): sem close_when, a description genérica ("SOMENTE quando as condições
# configuradas foram atendidas") não aponta pra NADA — a IA marcou true sozinha ao ouvir "ta bem
# obrigada". Porta Ai::PythonOrchestratorClient#encerrar_atendimento_rule (Rails, removido 19/08).
def test_sem_close_when_vira_proibicao_explicita_nao_a_description_generica_ambigua():
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when=None, close_message=None, collect_hint=None,
        known_attribute_keys=None,
    )
    desc = _descriptions(schema)["encerrar_atendimento"]

    assert desc.startswith("mantenha SEMPRE false")
    assert "SOMENTE quando as condições de encerramento configuradas foram atendidas" not in desc


def test_com_close_when_usa_a_condicao_configurada():
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when="cliente confirma que não quer mais nada",
        close_message=None, collect_hint=None, known_attribute_keys=None,
    )
    desc = _descriptions(schema)["encerrar_atendimento"]

    assert desc == (
        "true SOMENTE quando as condições de encerramento configuradas forem atendidas: "
        "cliente confirma que não quer mais nada."
    )


def test_close_message_e_anexada_na_description_de_encerrar_atendimento():
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when="cliente confirma", close_message="Foi um prazer te atender!",
        collect_hint=None, known_attribute_keys=None,
    )
    desc = _descriptions(schema)["encerrar_atendimento"]

    assert "mensagem de despedida sugerida: 'Foi um prazer te atender!'" in desc


def test_collect_hint_ausente_nao_mexe_na_description_de_dados_coletados():
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when=None, close_message=None, collect_hint=None,
        known_attribute_keys=None,
    )
    desc = _descriptions(schema)["dados_coletados"]

    assert desc == orchestrator._BASE_REPLY_SCHEMA["properties"][orchestrator.DADOS_KEY]["description"]


def test_collect_hint_um_atributo_com_tipo_e_opcoes():
    hint = {"items": [{"attribute": "ja_cliente", "type": "choice",
                       "options": ["Já é cliente", "Nova contratação"], "required": True, "hint": None}]}
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when=None, close_message=None, collect_hint=hint,
        known_attribute_keys=None,
    )
    desc = _descriptions(schema)["dados_coletados"]

    assert "extraia especificamente o dado referente a 'ja_cliente'" in desc
    assert "tipo: choice" in desc
    assert "opções válidas: Já é cliente, Nova contratação" in desc
    assert "OBRIGATÓRIO" in desc


def test_collect_hint_opcional_sem_tipo_nem_opcoes():
    hint = {"items": [{"attribute": "observacao", "type": None, "options": [], "required": False, "hint": None}]}
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when=None, close_message=None, collect_hint=hint,
        known_attribute_keys=None,
    )
    desc = _descriptions(schema)["dados_coletados"]

    assert "'observacao'" in desc
    assert "opcional" in desc
    assert "tipo:" not in desc
    assert "opções válidas" not in desc


def test_collect_hint_multi_atributo():
    hint = {"items": [
        {"attribute": "cidade", "type": None, "options": [], "required": True, "hint": None},
        {"attribute": "viabilidade", "type": None, "options": [], "required": True, "hint": None},
    ]}
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when=None, close_message=None, collect_hint=hint,
        known_attribute_keys=None,
    )
    desc = _descriptions(schema)["dados_coletados"]

    assert '"cidade"' in desc
    assert '"viabilidade"' in desc
    assert "CADA um como um item PRÓPRIO" in desc


def test_collect_hint_sem_atributos_declarados_e_tratado_como_ausente():
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when=None, close_message=None, collect_hint={"items": []},
        known_attribute_keys=None,
    )
    desc = _descriptions(schema)["dados_coletados"]

    assert desc == orchestrator._BASE_REPLY_SCHEMA["properties"][orchestrator.DADOS_KEY]["description"]


# Cada chamada tem que ser uma cópia independente — sem isso, uma conta com transfer_when vazaria a
# description customizada pra OUTRA conta cuja próxima chamada não passasse o parâmetro (o dict
# seria mutado in-place e reusado como se fosse o template).
def test_cada_chamada_devolve_uma_copia_independente_nao_mutua_o_template():
    orchestrator._build_reply_schema(
        transfer_when="condição da conta A", close_when=None, close_message=None, collect_hint=None,
        known_attribute_keys=None,
    )
    schema_b = orchestrator._build_reply_schema(
        transfer_when=None, close_when=None, close_message=None, collect_hint=None,
        known_attribute_keys=None,
    )

    assert "condição da conta A" not in _descriptions(schema_b)["transferir_humano"]
    assert "condição da conta A" not in orchestrator._BASE_REPLY_SCHEMA["properties"][orchestrator.TRANSFERIR_KEY]["description"]


def test_handoff_target_nao_referencia_mais_lista_nas_instructions():
    schema = orchestrator._build_reply_schema(
        transfer_when=None, close_when=None, close_message=None, collect_hint=None,
        known_attribute_keys=None,
    )
    desc = schema["properties"][orchestrator.HANDOFF_TARGET_KEY]["description"]

    assert "nas instructions" not in desc
