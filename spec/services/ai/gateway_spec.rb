require 'rails_helper'

# Golden master do Ai::Gateway — trava o COMPORTAMENTO OBSERVÁVEL atual (sequência de ai_events +
# estado do run/conversa/mensagens) como linha de base ANTES de refatorar o God object. Deve passar
# IDÊNTICO depois da refatoração; qualquer mudança de ordem/nome de evento é regressão.
#
# As sequências de eventos nos `expect(event_types(convo)).to eq(%w[...])` foram CAPTURADAS rodando
# o próprio spec (não são inventadas). Ao evoluir o Gateway de propósito, atualize o golden aqui.
#
# Rodar:  docker compose exec rails bundle exec rspec spec/services/ai/gateway_spec.rb
#
# O LLM é isolado stubando o ÚNICO ponto de chamada do Gateway: Ai::ModelRouter.decide.
RSpec.describe Ai::Gateway do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end

  before do
    account.enable_features!('ai_core')
    # Mantém a caixa "aberta" p/ o gate de resposta ao vivo bater de forma determinística.
    allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
    # Isola os colaboradores de I/O (embedding/LLM/HTTP) — o golden master é do ORQUESTRADOR.
    allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
    allow(Ai::Workers::MediaProcessor).to receive(:process).and_return(nil)
    allow(Ai::Workers::Summary).to receive(:generate).and_return(nil)
  end

  # --- Helpers (sem factory nova; cria direto como o resto do repo) --------------------

  # Um único department ativo → DepartmentResolver resolve por 'single' SEM chamar o classificador.
  def create_department(behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' }, transfer_rules: {}, close_rules: {})
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento',
                           status: 'active', behavior: behavior, transfer_rules: transfer_rules,
                           close_rules: close_rules)
  end

  def create_binding(mode:)
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: mode, active: true)
  end

  # Molda o retorno de Ai::ModelRouter.decide (mesma forma do serviço real) e stuba o único ponto
  # de chamada de LLM do Gateway. `decision` dirige o cenário (reply/handoff/tool/close).
  def stub_decision(decision, status: 'recorded')
    stub_decisions([decision, status])
  end

  # Stuba turnos sequenciais de Ai::ModelRouter.decide (usado no tool+followup, que chama 2x).
  # Cada item é o hash de decisão OU um par [decision, status].
  def stub_decisions(*turns)
    results = turns.map do |turn|
      decision, status = turn.is_a?(Array) ? turn : [turn, 'recorded']
      { provider: 'openai', model: 'gpt-4.1-mini', decision: decision,
        tokens_in: 10, tokens_out: 5, cost: 0.0, latency_ms: 1, status: status }
    end
    allow(Ai::ModelRouter).to receive(:decide).and_return(*results)
  end

  # Cria a mensagem do cliente e roda o Gateway para o binding dado. Devolve a conversa recarregada.
  def deliver(content, binding:, mode:)
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    message = create(:message, account: account, inbox: inbox, conversation: convo,
                               message_type: 'incoming', content: content)
    described_class.new(message: message, agent_inbox: binding, mode: mode).run
    convo.reload
  end

  # Assinatura primária do golden: a sequência ORDENADA de eventos da conversa.
  def event_types(convo)
    Ai::Event.where(conversation_id: convo.id).order(:id).pluck(:event_type)
  end

  def run_for(convo)
    Ai::Run.find_by(conversation_id: convo.id)
  end

  # === Cenário 1: SHADOW — só registra intenção, zero efeito colateral ================
  context 'shadow (binding observa; nunca responde/age)' do
    it 'records intention only and creates no outgoing message' do
      create_department
      binding = create_binding(mode: 'shadow')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'Olá! Como posso ajudar?' })

      convo = deliver('Oi, tudo bem?', binding: binding, mode: 'shadow')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made reply.intended
                                       ])

      # Shadow não envia nada ao cliente.
      expect(convo.messages.outgoing.count).to eq(0)
      expect(run_for(convo).status).to eq('recorded')
    end
  end

  # === Cenário 2: REPLY (ao vivo) — responde o cliente ================================
  context 'reply (ao vivo)' do
    it 'sends the reply and records the run' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'Claro, posso ajudar com isso!' })

      convo = deliver('Preciso de ajuda', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made reply.sent
                                       ])

      expect(convo.messages.outgoing.last&.content).to eq('Claro, posso ajudar com isso!')
      expect(run_for(convo).status).to eq('recorded')
    end

    # Medição de prompt caching (#reorder): cached_tokens do ModelRouter -> Ai::Run + evento decision.made.
    it 'propaga cached_tokens para o Ai::Run e para o evento decision.made' do
      create_department
      binding = create_binding(mode: 'live')
      allow(Ai::ModelRouter).to receive(:decide).and_return(
        { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'decision' => 'reply', 'reply_text' => 'Oi!' },
          tokens_in: 100, tokens_out: 20, cached_tokens: 64, cost: 0.0, latency_ms: 1, status: 'recorded' }
      )

      convo = deliver('Olá', binding: binding, mode: 'live')

      expect(run_for(convo).cached_tokens).to eq(64)
      made = Ai::Event.where(conversation_id: convo.id, event_type: 'decision.made').last
      expect(made.payload['cached_tokens']).to eq(64)
    end
  end

  # === Cenário 2b: CRÉDITO DE IA ESGOTADO (billing Fase 2) ============================
  context 'crédito de IA esgotado (saldo zerado)' do
    it 'não responde: handoff pro humano, nota interna, sem reply.sent nem decisão' do
      create_department
      binding = create_binding(mode: 'live')
      account.create_ai_credit_balance!(plan_credits: 0, extra_credits: 0)
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'NÃO deveria responder' })

      convo = deliver('Preciso de ajuda', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved
                                         handoff.executed handoff.assign_failed handoff.credit_exhausted
                                       ])
      # A IA não respondeu ao cliente (a nota interna é privada); o modelo nem foi chamado.
      expect(convo.messages.outgoing.where(private: false).count).to eq(0)
      expect(convo.messages.where(private: true).count).to eq(1)
      expect(Ai::ModelRouter).not_to have_received(:decide)
      expect(convo.additional_attributes['ai_handoff']).to be(true)
      expect(run_for(convo).status).to eq('credit_exhausted')
    end

    it 'conta SEM balance responde normalmente (fail-open)' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'Claro!' })

      convo = deliver('oi', binding: binding, mode: 'live')

      expect(event_types(convo)).to include('reply.sent')
      expect(event_types(convo)).not_to include('handoff.credit_exhausted')
    end

    it 'com custom_llm_api_key ativo, pula o enforcement mesmo com saldo zerado' do
      create_department
      binding = create_binding(mode: 'live')
      account.create_ai_credit_balance!(plan_credits: 0, extra_credits: 0)
      account.enable_features!('custom_llm_api_key')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'Respondo com a chave própria' })

      convo = deliver('oi', binding: binding, mode: 'live')

      expect(event_types(convo)).to include('reply.sent')
      expect(event_types(convo)).not_to include('handoff.credit_exhausted')
    end
  end

  # === Cenário 3: HANDOFF → HUMANO ====================================================
  context 'handoff para humano (modelo pede transferência; agente sem rota IA→IA)' do
    it 'replies, transfers and hands to a human' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'handoff', 'reply_text' => 'Vou te transferir para um atendente 🙂' })

      convo = deliver('Quero falar com um humano', binding: binding, mode: 'live')

      # O inbox de teste não tem membros humanos atribuíveis e o agente não tem team_id → a atribuição
      # não acha ninguém e agora emite handoff.assign_failed (antes era handoff.assigned silencioso com
      # assignee nil). Com um membro/time configurado, o terminal seria handoff.assigned/_fallback.
      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made reply.sent
                                         handoff.executed handoff.assign_failed
                                       ])

      # Efeitos do handoff: reabre, marca handoff e registra a transferência nativa.
      expect(convo.status).to eq('open')
      expect(convo.additional_attributes['ai_handoff']).to be(true)
      expect(Ai::CapabilityExecution.where(conversation_id: convo.id, capability_key: 'conversation.transfer')).to exist
    end
  end

  # === Cenário 4: TOOL + FOLLOWUP → reply (ao vivo) ===================================
  context 'tool + followup (executa ferramenta e responde com o resultado)' do
    it 'executes the tool, takes a 2nd turn and replies' do
      department = create_department
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'contact.read',
                       implementation_type: 'capability', capability_key: 'contact.read', status: 'active')
      binding = create_binding(mode: 'live')
      # 1º turno: modelo invoca a ferramenta; 2º turno (após o resultado): responde o cliente.
      stub_decisions(
        { 'decision' => 'invoke_tool', 'tool' => { 'name' => 'contact.read', 'input' => {} } },
        { 'decision' => 'reply', 'reply_text' => 'Seu cadastro está em dia!' }
      )

      convo = deliver('Confere meu cadastro?', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made tool.executed
                                         tool.followup reply.sent
                                       ])

      expect(convo.messages.outgoing.last&.content).to eq('Seu cadastro está em dia!')
      expect(Ai::CapabilityExecution.where(conversation_id: convo.id, capability_key: 'contact.read')).to exist
    end

    # Enxugamento da 2ª chamada: o prompt do tool.followup é MENOR que o da 1ª (context.assembled).
    it 'a 2ª chamada usa um prompt ENXUTO (menor que o context.assembled do mesmo run)' do
      department = create_department
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'contact.read',
                       implementation_type: 'capability', capability_key: 'contact.read', status: 'active')
      binding = create_binding(mode: 'live')
      stub_decisions(
        { 'decision' => 'invoke_tool', 'tool' => { 'name' => 'contact.read', 'input' => {} } },
        { 'decision' => 'reply', 'reply_text' => 'ok' }
      )

      convo = deliver('Confere meu cadastro?', binding: binding, mode: 'live')

      full = Ai::Event.where(conversation_id: convo.id, event_type: 'context.assembled').last.payload['prompt_chars']
      slim = Ai::Event.where(conversation_id: convo.id, event_type: 'tool.followup').last.payload['prompt_chars']
      expect(slim).to be_positive
      expect(slim).to be < full
    end

    it 'followup com decision handoff: transfere (handoff.executed) — inalterado com o prompt enxuto' do
      department = create_department
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'contact.read',
                       implementation_type: 'capability', capability_key: 'contact.read', status: 'active')
      binding = create_binding(mode: 'live')
      stub_decisions(
        { 'decision' => 'invoke_tool', 'tool' => { 'name' => 'contact.read', 'input' => {} } },
        { 'decision' => 'handoff', 'reply_text' => 'Vou te transferir para um atendente.' }
      )

      convo = deliver('Confere meu cadastro?', binding: binding, mode: 'live')

      expect(event_types(convo)).to include('tool.followup', 'handoff.executed')
    end

    it 'followup com decision close: encerra (close.executed + resolved)' do
      department = create_department
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'contact.read',
                       implementation_type: 'capability', capability_key: 'contact.read', status: 'active')
      binding = create_binding(mode: 'live')
      stub_decisions(
        { 'decision' => 'invoke_tool', 'tool' => { 'name' => 'contact.read', 'input' => {} } },
        { 'decision' => 'close', 'reply_text' => 'Pronto, resolvido! Até logo.' }
      )

      convo = deliver('Confere meu cadastro?', binding: binding, mode: 'live')

      expect(event_types(convo)).to include('tool.followup', 'close.executed')
      expect(convo.status).to eq('resolved')
    end

    it 'followup que devolve invoke_tool: cai no safety-net e SÓ responde (não executa 2ª ferramenta)' do
      department = create_department
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'contact.read',
                       implementation_type: 'capability', capability_key: 'contact.read', status: 'active')
      binding = create_binding(mode: 'live')
      stub_decisions(
        { 'decision' => 'invoke_tool', 'tool' => { 'name' => 'contact.read', 'input' => {} } },
        { 'decision' => 'invoke_tool', 'tool' => { 'name' => 'contact.read', 'input' => {} },
          'reply_text' => 'texto de segurança' }
      )

      convo = deliver('Confere meu cadastro?', binding: binding, mode: 'live')

      expect(Ai::CapabilityExecution.where(conversation_id: convo.id).count).to eq(1) # single hop: só a 1ª executa
      expect(convo.messages.outgoing.last&.content).to eq('texto de segurança')
    end
  end

  # === Cenário 5: CLOSE (ao vivo) — despedida + resolve ===============================
  context 'close (ao vivo)' do
    # (c) Sem mensagem da Finalização E sem reply_text: fecha em SILÊNCIO (comportamento preservado).
    it 'sem mensagem nem reply_text: resolve em silêncio (como antes)' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'close' })

      convo = deliver('Obrigado, era só isso!', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made close.executed
                                       ])
      expect(convo.messages.outgoing.count).to eq(0)
      expect(convo.status).to eq('resolved')
    end

    # (a) Mensagem da Finalização presente: enviada como despedida ANTES de resolver (prioridade máxima,
    # vence até o reply_text do modelo).
    it 'com close_rules[message]: envia a despedida da Finalização e resolve' do
      create_department(close_rules: { 'message' => 'Foi um prazer! Até a próxima 👋' })
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'close', 'reply_text' => 'tchau gerado pelo modelo' })

      convo = deliver('Obrigado!', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made reply.sent close.executed
                                       ])
      expect(convo.messages.outgoing.last.content).to eq('Foi um prazer! Até a próxima 👋')
      expect(convo.status).to eq('resolved')
    end

    # (b) Sem mensagem da Finalização, mas o modelo gerou reply_text: usa a despedida do modelo (fallback,
    # antes descartada).
    it 'sem close_rules[message] mas com reply_text: usa a despedida do modelo' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'close', 'reply_text' => 'Foi ótimo te ajudar, até logo!' })

      convo = deliver('valeu', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made reply.sent close.executed
                                       ])
      expect(convo.messages.outgoing.last.content).to eq('Foi ótimo te ajudar, até logo!')
      expect(convo.status).to eq('resolved')
    end
  end

  # === Cenário 5b: DECISION FORA DO CONTRATO (rede de segurança) =======================
  # O modelo às vezes devolve um `decision` inválido (ex.: "text") com um reply_text válido. Antes o
  # Gateway descartava tudo em silêncio; agora trata como reply (com texto) ou registra o desvio.
  context 'decision desconhecida (fora do contrato)' do
    it 'com reply_text: envia como reply normalmente + registra decision.unknown_kind' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'text', 'reply_text' => 'Qual seu nome pra seguirmos? 😊' })

      convo = deliver('Queria contratar', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made decision.unknown_kind reply.sent
                                       ])
      expect(convo.messages.outgoing.last&.content).to eq('Qual seu nome pra seguirmos? 😊')
    end

    it 'sem reply_text: só registra decision.unknown_kind, não envia nada e não quebra' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'sei_la', 'reply_text' => '' })

      convo = deliver('oi', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made decision.unknown_kind
                                       ])
      expect(convo.messages.outgoing.count).to eq(0)
      expect(run_for(convo).status).to eq('recorded')
    end

    it 'noop (valor VÁLIDO do contrato) NÃO dispara decision.unknown_kind nem envia nada' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'noop' })

      convo = deliver('...', binding: binding, mode: 'live')

      expect(event_types(convo)).not_to include('decision.unknown_kind')
      expect(convo.messages.outgoing.count).to eq(0)
    end
  end

  # === Cenário 6: HANDOFF → IA (roteia para outro agente e re-enfileira) ==============
  context 'handoff para outra IA (agente de destino na allowlist)' do
    it 'routes to the target team and re-enqueues the Gateway' do
      create_department
      team = create(:team, account: account)
      target = Ai::Agent.create!(account: account, name: 'Financeiro', status: 'active',
                                 ai_operation_profile_id: profile.id, team_id: team.id)
      agent.update!(handoff_agent_ids: [target.id])
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'handoff', 'handoff_target' => 'Financeiro' })

      convo = deliver('Quero falar sobre a fatura', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made handoff.routed
                                       ])

      # Roteou: conversa passa para o time do agente de destino; nada é enviado ao cliente ainda.
      expect(convo.team_id).to eq(team.id)
      expect(convo.messages.outgoing.count).to eq(0)
    end
  end

  # === Cenário 7: NO_DEPARTMENT — encerra cedo (agente sem department ativo) ==========
  context 'sem department resolvido' do
    it 'finalizes early as no_department' do
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'nunca chega aqui' })

      convo = deliver('Olá', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[message.received department.resolved])

      expect(run_for(convo).status).to eq('no_department')
      expect(convo.messages.outgoing.count).to eq(0)
    end
  end

  # === Cenário 8: ERROR — exceção na etapa de conhecimento vira erro TIPADO ============
  context 'erro tipado (falha na busca de conhecimento)' do
    it 'records status error with the knowledge_timeout category' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'nunca chega aqui' })
      # Força a exceção DENTRO da etapa :knowledge → classify_error mapeia p/ 'knowledge_timeout'.
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_raise(StandardError, 'pgvector caiu')

      convo = deliver('Tem cobertura na minha cidade?', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[message.received department.resolved])

      expect(run_for(convo).status).to eq('error')
      expect(run_for(convo).error_type).to eq('knowledge_timeout')
    end
  end

  # === Cenário 9: OVERRIDE de department por conversa (Fase 2) =========================
  context 'override de department por conversa (Fase 2)' do
    def deliver_with_override(content, override_id, binding:)
      convo = create(:conversation, account: account, inbox: inbox, status: 'open',
                                    additional_attributes: { 'ai_department_override' => override_id })
      message = create(:message, account: account, inbox: inbox, conversation: convo,
                                 message_type: 'incoming', content: content)
      described_class.new(message: message, agent_inbox: binding, mode: 'live').run
      convo.reload
    end

    it 'honors a valid override (department.resolved method = override) and skips the classifier' do
      create_department
      dept_b = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Vendas', status: 'active',
                                      behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' })
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })
      allow(Ai::DepartmentResolver).to receive(:classify).and_return(nil) # se rodasse, não seria 'override'

      convo = deliver_with_override('oi', dept_b.id, binding: binding)

      event = Ai::Event.find_by(conversation_id: convo.id, event_type: 'department.resolved')
      expect(event.payload['method']).to eq('override')
      expect(event.payload['department_id']).to eq(dept_b.id)
      expect(Ai::DepartmentResolver).not_to have_received(:classify)
    end

    it 'tags department-override-indisponivel and proceeds normally when the override is unavailable' do
      create_department # 1 department ativo -> override para outro id cai em 'single'
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })

      convo = deliver_with_override('oi', 999_999, binding: binding)

      expect(convo.label_list).to include('department-override-indisponivel')
      expect(run_for(convo).status).to eq('recorded')
      expect(convo.messages.outgoing.count).to eq(1)
    end
  end

  # === Cenário 10: GUARDA ANTI-LOOP (rede de segurança) ================================
  context 'anti-loop (rede de segurança)' do
    # Semeia 2 respostas anteriores parafraseadas (dados reais do bug) + incoming do cliente entre elas.
    def seed_loop_history(convo)
      Ai::Run.create!(account_id: account.id, conversation_id: convo.id, ai_agent_id: agent.id,
                      run_type: 'decision', mode: 'live', status: 'recorded', created_at: 6.minutes.ago,
                      decision: { 'decision' => 'reply',
                                  'reply_text' => 'Você mencionou que quer contratar internet para Cunha Porá, correto?' })
      create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming',
                       content: 'sim', created_at: 5.minutes.ago)
      Ai::Run.create!(account_id: account.id, conversation_id: convo.id, ai_agent_id: agent.id,
                      run_type: 'decision', mode: 'live', status: 'recorded', created_at: 4.minutes.ago,
                      decision: { 'decision' => 'reply',
                                  'reply_text' => 'Você deseja contratar internet em Cunha Porá, correto?' })
      create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming',
                       content: 'sim', created_at: 3.minutes.ago)
    end

    def deliver_after_loop_history(reply_texts)
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      seed_loop_history(convo)
      message = create(:message, account: account, inbox: inbox, conversation: convo,
                                 message_type: 'incoming', content: 'sim')
      stub_decisions(*reply_texts.map { |t| { 'decision' => 'reply', 'reply_text' => t } })
      described_class.new(message: message, agent_inbox: create_binding(mode: 'live'), mode: 'live').run
      convo.reload
    end

    before { create_department }

    it '1ª detecção: nudge + retry; envia a resposta regenerada (fora do loop)' do
      convo = deliver_after_loop_history([
                                           'Você está interessado em contratar internet em Cunha Porá, correto?',
                                           'Perfeito! Temos os planos Fibra 300, 500 e 1 Giga. Qual te interessa?'
                                         ])

      expect(event_types(convo)).to include('reply.loop_detected', 'reply.loop_retry', 'reply.sent')
      expect(convo.messages.outgoing.last&.content)
        .to eq('Perfeito! Temos os planos Fibra 300, 500 e 1 Giga. Qual te interessa?')
    end

    it 'persistência: retry ainda em loop -> handoff forçado, sem enviar a resposta problemática' do
      convo = deliver_after_loop_history([
                                           'Você está interessado em contratar internet em Cunha Porá, correto?',
                                           'Você deseja contratar internet em Cunha Porá, correto?'
                                         ])

      events = event_types(convo)
      expect(events).to include('reply.loop_detected', 'reply.loop_retry', 'handoff.loop_forced')
      expect(events).not_to include('reply.sent')
      expect(convo.messages.outgoing.count).to eq(0)
    end
  end

  # === Camada B: etapa de slot travada -> avisa o cliente e TRANSFERE (não força avanço) ==========
  context 'rede de segurança: etapa de slot travada -> handoff para humano' do
    def slot_department(turns)
      dept = create_department(transfer_rules: { 'stuck_handoff_turns' => turns })
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Nome completo',
                                'collect' => { 'attribute' => 'nome', 'type' => 'text', 'required' => true } }
                            ])
      dept
    end

    def run_turn(convo, binding, text)
      message = create(:message, account: account, inbox: inbox, conversation: convo,
                                 message_type: 'incoming', content: text)
      described_class.new(message: message, agent_inbox: binding, mode: 'live').run
      convo.reload
    end

    def stub_reply
      stub_decisions(
        { 'decision' => 'reply', 'reply_text' => 'Qual seu nome?' },
        { 'decision' => 'reply', 'reply_text' => 'Pode me dizer seu nome?' },
        { 'decision' => 'reply', 'reply_text' => 'Preciso do seu nome, por favor.' }
      )
    end

    it 'cliente RESPONDENDO (mesmo junk) captura o valor e NÃO transfere por trava' do
      slot_department(3)
      binding = create_binding(mode: 'live')
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      stub_reply

      run_turn(convo, binding, 'oi') # captura "oi" como nome (guarda e segue)

      expect(event_types(convo)).not_to include('step.stuck_handoff')
      expect(convo.additional_attributes['ai_collected_facts']).to include('nome' => 'oi')
    end

    # Cliente SUMIDO = mensagens sem texto usável (branco): nada a capturar -> conta trava -> handoff.
    it 'X=3: cliente sumido por 3 turnos -> avisa o cliente ANTES, transfere e emite step.stuck_handoff' do
      slot_department(3)
      binding = create_binding(mode: 'live')
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      allow(Ai::HandoffSummaryJob).to receive(:perform_later)
      stub_reply

      run_turn(convo, binding, '') # turno 1 (sem texto usável)
      run_turn(convo, binding, '') # turno 2
      run_turn(convo, binding, '') # turno 3 -> handoff

      aggregate_failures do
        expect(event_types(convo)).to include('step.stuck_handoff')
        # avisou o cliente (a última mensagem enviada é o aviso, não a pergunta do modelo)
        expect(convo.messages.outgoing.last.content).to include('encaminhar')
        # transferiu de verdade (ação nativa de transfer) e NÃO forçou avanço com dado faltando
        expect(Ai::CapabilityExecution.where(conversation_id: convo.id, capability_key: 'conversation.transfer')).to exist
        # Gap 4 v2: cliente sumido = teto ABSOLUTO (max_turns). O Resumo diz "não conseguiu avançar a etapa
        # ... após N mensagens", NÃO "tentou coletar sem sucesso" (não presume tentativa falha).
        summary_reason = nil
        expect(Ai::HandoffSummaryJob).to have_received(:perform_later) { |_id, r| summary_reason = r }
        expect(summary_reason).to match(/não conseguiu avançar a etapa "Nome completo" após 3 mensagens/)
        expect(summary_reason).not_to include('sem sucesso') # não chama travamento de "tentativa falha"
        # telemetria
        ev = Ai::Event.where(conversation_id: convo.id, event_type: 'step.stuck_handoff').last
        expect(ev.payload).to include('attribute' => 'nome', 'step_name' => 'Nome completo', 'turns' => 3, 'reason' => 'max_turns')
      end
    end

    # Gap 4 v2: recusa GENUÍNA (declínio) numa etapa obrigatória -> rede de recusa. O Resumo diz que o
    # cliente NÃO FORNECEU o dado (recusou N vezes), NÃO "não avançou" — distingue recusa de travamento.
    it 'recusa consecutiva (declínio) -> handoff com reason declined e texto de "não forneceu o dado"' do
      slot_department(2) # required: true; teto de recusa = stuck_limit = 2
      binding = create_binding(mode: 'live')
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      allow(Ai::HandoffSummaryJob).to receive(:perform_later)
      stub_reply

      run_turn(convo, binding, 'não tenho') # recusa 1
      run_turn(convo, binding, 'não tenho') # recusa 2 -> teto -> declined

      aggregate_failures do
        ev = Ai::Event.where(conversation_id: convo.id, event_type: 'step.stuck_handoff').last
        expect(ev.payload).to include('reason' => 'declined', 'step_name' => 'Nome completo')
        summary_reason = nil
        expect(Ai::HandoffSummaryJob).to have_received(:perform_later) { |_id, r| summary_reason = r }
        expect(summary_reason).to match(/não forneceu o dado essencial "Nome completo".*recusou 2 vezes/)
      end
    end

    it 'X=0 desligado: cliente sumido nunca transfere por trava' do
      slot_department(0)
      binding = create_binding(mode: 'live')
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      stub_reply

      4.times { run_turn(convo, binding, '') } # cliente sumido, mas X=0

      expect(event_types(convo)).not_to include('step.stuck_handoff')
      expect(convo.additional_attributes['ai_step_index']).to eq(0)
    end
  end

  # === (b)-core: DESFECHO declarado pela etapa (on_complete) -> conclusão DETERMINÍSTICA ==========
  context 'conclusão declarada: etapa terminal com on_complete roteia pela whitelist' do
    let!(:team) { create(:team, account: account, name: 'Comercial') }

    def conclusion_department(final_step)
      dept = create_department
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Cadastro',
                                'collect' => { 'attribute' => 'nome', 'type' => 'text', 'required' => true } },
                              final_step
                            ])
      dept
    end

    def run_turn(convo, binding, text)
      message = create(:message, account: account, inbox: inbox, conversation: convo,
                                 message_type: 'incoming', content: text)
      described_class.new(message: message, agent_inbox: binding, mode: 'live').run
      convo.reload
    end

    # A PROVA do (b)-core: o modelo NÃO emite step_completed no turno 2 e a conversa conclui mesmo assim.
    it 'obrigatórios preenchidos -> conclui SEM step_completed: transfere pela whitelist, reason conclusao, status open' do
      agent.update!(team_id: nil, handoff_team_ids: [team.id])
      conclusion_department({ 'name' => 'Finalização',
                              'on_complete' => { 'action' => 'handoff_human', 'team_id' => team.id, 'reason' => 'conclusao' } })
      binding = create_binding(mode: 'live')
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      allow(Ai::HandoffSummaryJob).to receive(:perform_later)
      stub_decisions(
        { 'decision' => 'reply', 'reply_text' => 'Recebi seu nome!' },         # turno 1: captura nome, avança
        { 'decision' => 'reply', 'reply_text' => 'Foi tudo certo, até logo!' }  # turno 2: SEM step_completed
      )

      run_turn(convo, binding, 'João Silva') # turno 1 -> nome
      run_turn(convo, binding, 'obrigado')   # turno 2 -> conclusão determinística

      aggregate_failures do
        expect(convo.additional_attributes['ai_collected_facts']).to include('nome' => 'João Silva')
        expect(event_types(convo)).to include('conclusion.executed')
        expect(event_types(convo)).not_to include('step.stuck_handoff') # é conclusão, não give-up
        expect(Ai::CapabilityExecution.where(conversation_id: convo.id, capability_key: 'conversation.transfer')).to exist
        expect(convo.team_id).to eq(team.id)     # roteou pelo team_id declarado (na whitelist)
        expect(convo.status).to eq('open')       # open + assigned (mark_handed_off), NÃO resolved
        reason = nil
        expect(Ai::HandoffSummaryJob).to have_received(:perform_later) { |_id, r| reason = r }
        expect(reason).to eq('conclusao')        # prova de mutação por nome
      end
    end

    it 'action close -> resolve a conversa (não transfere)' do
      conclusion_department({ 'name' => 'Finalização', 'on_complete' => { 'action' => 'close', 'reason' => 'conclusao' } })
      binding = create_binding(mode: 'live')
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      stub_decisions(
        { 'decision' => 'reply', 'reply_text' => 'Recebi!' },
        { 'decision' => 'reply', 'reply_text' => 'Encerrando, até logo!' }
      )

      run_turn(convo, binding, 'João')
      run_turn(convo, binding, 'tchau')

      aggregate_failures do
        expect(event_types(convo)).to include('conclusion.executed')
        expect(Ai::CapabilityExecution.where(conversation_id: convo.id, capability_key: 'conversation.resolve')).to exist
        expect(convo.status).to eq('resolved')
      end
    end
  end

  # === Fase 1: erro de PROVEDOR (status error) -> handoff em vez de silêncio ==========
  context 'provider indisponível (status error): transfere com nota privada, sem mensagem ao cliente' do
    it 'erro de provedor -> nota privada + transferência (reason provider_unavailable), NÃO cai no silêncio' do
      create_department
      binding = create_binding(mode: 'live')
      allow(Ai::HandoffSummaryJob).to receive(:perform_later)
      stub_decision({}, status: 'error') # o provedor falhou (rate-limit/cota): decisão vazia + status error

      convo = deliver('oi', binding: binding, mode: 'live')

      aggregate_failures do
        # não é mais silêncio: transferiu com motivo próprio
        expect(event_types(convo)).to include('handoff.provider_unavailable')
        expect(event_types(convo)).not_to include('decision.unknown_kind')
        expect(Ai::CapabilityExecution.where(conversation_id: convo.id, capability_key: 'conversation.transfer')).to exist
        # NOTA PRIVADA ao atendente com o motivo técnico (o cliente nunca vê)
        note = convo.messages.where(private: true).last
        expect(note).to be_present
        expect(note.content).to include('cota/billing')
        # DECISÃO DE PRODUTO: NENHUMA mensagem automática ao cliente
        expect(convo.messages.outgoing.where(private: false)).to be_empty
        # resumo do handoff com o reason próprio (prova de mutação por nome)
        reason = nil
        expect(Ai::HandoffSummaryJob).to have_received(:perform_later) { |_id, r| reason = r }
        expect(reason).to eq('provider_unavailable')
      end
    end

    it 'em SHADOW: erro de provedor apenas registra (não transfere nem escreve nota)' do
      create_department
      binding = create_binding(mode: 'shadow')
      stub_decision({}, status: 'error')

      convo = deliver('oi', binding: binding, mode: 'shadow')

      aggregate_failures do
        expect(event_types(convo)).not_to include('handoff.provider_unavailable')
        expect(convo.messages.where(private: true)).to be_empty
      end
    end
  end

  # === Fase 2: e-mail aos admins da conta quando o erro de provedor vira handoff ========
  # Cota/billing é problema de quem paga, não do atendente. throttle 1h por (conta, provedor).
  context 'provider indisponível: avisa os admins da conta (throttled)' do
    it 'envia o e-mail no PRIMEIRO provider_error (linguagem de dono, para os admins da conta)' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({}, status: 'error')

      expect { deliver('oi', binding: binding, mode: 'live') }
        .to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :provider_error_handoff)
    end

    it 'NÃO envia um SEGUNDO e-mail dentro da janela (mesma conta+provedor)' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({}, status: 'error')
      # null_store (teste) não persiste; um MemoryStore real exercita o throttle
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect do
        deliver('oi', binding: binding, mode: 'live')
        deliver('olá?', binding: binding, mode: 'live')
      end.to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :provider_error_handoff).once
    end

    it 'envia DE NOVO depois que a janela do throttle expira' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({}, status: 'error')
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      deliver('oi', binding: binding, mode: 'live')

      expect do
        travel(Ai::Gateway::PROVIDER_ERROR_NOTIFY_TTL + 1.minute) do
          deliver('e agora?', binding: binding, mode: 'live')
        end
      end.to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :provider_error_handoff).once
    end

    it 'falha no envio do e-mail NÃO impede o handoff' do
      create_department
      binding = create_binding(mode: 'live')
      allow(Ai::HandoffSummaryJob).to receive(:perform_later)
      stub_decision({}, status: 'error')
      # o mailer explode; o handoff (já concluído antes do aviso) tem de sobreviver
      allow(AdministratorNotifications::AccountNotificationMailer)
        .to receive(:with).and_raise(StandardError, 'smtp down')

      convo = deliver('oi', binding: binding, mode: 'live')

      aggregate_failures do
        expect(event_types(convo)).to include('handoff.provider_unavailable')
        expect(Ai::CapabilityExecution.where(conversation_id: convo.id, capability_key: 'conversation.transfer')).to exist
        note = convo.messages.where(private: true).last
        expect(note&.content).to include('cota/billing')
      end
    end
  end

  # === collected — a memória de fatos ao vivo (ai_collected_facts) entra no prompt =====
  context 'collected inclui a memória de fatos ao vivo' do
    it 'passa ai_collected_facts em collected, com custom_attributes da conversa por cima' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'noop' })

      convo = create(:conversation, account: account, inbox: inbox, status: 'open',
                                    custom_attributes: { 'cidade' => 'Maravilha' },
                                    additional_attributes: {
                                      'ai_collected_facts' => { 'cidade' => 'Chapeco', 'tamanho_imovel' => '70m2' }
                                    })
      message = create(:message, account: account, inbox: inbox, conversation: convo,
                                 message_type: 'incoming', content: 'oi')

      captured = nil
      allow(Ai::PromptCompiler).to receive(:compile) do |**kwargs|
        captured = kwargs[:collected]
        'prompt-stub'
      end

      described_class.new(message: message, agent_inbox: binding, mode: 'live').run

      expect(captured['tamanho_imovel']).to eq('70m2') # fato ao vivo entra no prompt
      expect(captured['cidade']).to eq('Maravilha')    # custom_attribute da conversa vence o fato ao vivo
    end
  end

  # === Camadas 3/4: conhecimento SOB DEMANDA (worker decide se busca e de qual kind) ==========
  context 'conhecimento sob demanda' do
    def enable_worker!
      profile.update!(worker_overrides: { 'capture_judge' => { 'mode' => 'when_silent' } })
    end

    def stub_judge(**result)
      allow(Ai::Workers::CaptureJudge).to receive(:judge).and_return(result)
    end

    def fresh_message(content)
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      [convo, create(:message, account: account, inbox: inbox, conversation: convo,
                               message_type: 'incoming', content: content)]
    end

    it 'worker DESLIGADO (default): busca RAG todo turno, sem filtro de kind (regressão total)' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })

      convo = deliver('quero saber dos valores', binding: binding, mode: 'live')

      expect(Ai::KnowledgeRetriever).to have_received(:retrieve).with(hash_including(kinds: nil))
      expect(Ai::Run.where(conversation_id: convo.id, run_type: 'capture_judge')).to be_empty # worker não rodou
    end

    it 'worker LIGADO + asks_about=produto: busca com kinds:[produto] e a query do worker' do
      enable_worker!
      create_department
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'produto', query: 'planos e preços')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })

      convo = deliver('quero saber dos valores', binding: binding, mode: 'live')

      aggregate_failures do
        expect(Ai::KnowledgeRetriever).to have_received(:retrieve)
          .with(hash_including(kinds: ['produto'], query: 'planos e preços'))
        ev = Ai::Event.where(conversation_id: convo.id, event_type: 'knowledge.retrieved').last
        expect(ev.payload['source']).to eq('worker')
        expect(ev.payload['kinds']).to eq(['produto'])
      end
    end

    it 'worker LIGADO + sem pergunta (asks_about=nada) e etapa sem conhecimento declarado: NÃO busca + knowledge.skipped' do
      enable_worker!
      create_department # sem playbook -> current_step nil -> nenhuma etapa declara conhecimento
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'nada', query: '')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })

      convo = deliver('ok', binding: binding, mode: 'live')

      aggregate_failures do
        expect(Ai::KnowledgeRetriever).not_to have_received(:retrieve)
        expect(Ai::Event.where(conversation_id: convo.id, event_type: 'knowledge.skipped')).to exist
        ev = Ai::Event.where(conversation_id: convo.id, event_type: 'knowledge.retrieved').last
        expect(ev.payload['source']).to eq('none')
      end
    end

    it 'etapa que DECLARA conhecimento: busca a query/kinds declarados MESMO sem pergunta (source step)' do
      enable_worker!
      dept = create_department
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Planos', 'knowledge' => { 'query' => 'planos e preços', 'kinds' => ['produto'] } },
                              { 'name' => 'Fim' }
                            ])
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'nada', query: '')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return(['CHUNK'])

      convo = deliver('ok', binding: binding, mode: 'live')

      expect(Ai::KnowledgeRetriever).to have_received(:retrieve).with(hash_including(kinds: ['produto'], query: 'planos e preços'))
      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'knowledge.retrieved').last.payload['source']).to eq('step')
    end

    # ao TRANSITAR para uma etapa que DECLARA conhecimento, o retrieval acontece no MESMO turno (look-ahead).
    # A etapa ATUAL (Aparelhos) NÃO declara; só o look-ahead da etapa que ENTRA (Planos) dispara.
    it 'invariante: transição para etapa que declara conhecimento busca no MESMO turno (look-ahead)' do
      enable_worker!
      dept = create_department
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Aparelhos', 'instructions' => 'Pergunte quantos aparelhos o cliente tem.',
                                'collect' => { 'attribute' => 'aparelhos', 'type' => 'number', 'required' => true } },
                              { 'name' => 'Planos', 'knowledge' => { 'query' => 'planos e preços', 'kinds' => ['produto'] } },
                              { 'name' => 'Fim' }
                            ])
      binding = create_binding(mode: 'live')
      stub_judge(status: 'answered', value: '5', asks_about: 'nada', query: '')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return(['CHUNK'])

      convo = deliver('5', binding: binding, mode: 'live')

      aggregate_failures do
        expect(convo.additional_attributes['ai_step_index'].to_i).to eq(1) # avançou Aparelhos->Planos: é a transição
        expect(Ai::KnowledgeRetriever).to have_received(:retrieve).with(hash_including(kinds: ['produto']))
        expect(Ai::Event.where(conversation_id: convo.id, event_type: 'knowledge.retrieved').last.payload['source']).to eq('step')
      end
    end

    # Não-vazamento (o risco real do look-ahead): o conhecimento entra no contexto DURANTE Aparelhos, mas a
    # coleta não é curto-circuitada — a etapa NÃO avança e o prompt segue ancorado em Aparelhos (step 0).
    it 'não-vazamento: conhecimento antecipado NÃO avança a etapa nem muda a âncora do prompt' do
      enable_worker!
      dept = create_department
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Aparelhos', 'instructions' => 'Pergunte quantos aparelhos o cliente tem.',
                                'collect' => { 'attribute' => 'aparelhos', 'type' => 'number', 'required' => true } },
                              { 'name' => 'Planos', 'knowledge' => { 'query' => 'planos e preços', 'kinds' => ['produto'] } },
                              { 'name' => 'Fim' }
                            ])
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'nada', query: '') # NÃO preencheu o slot
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'Quantos aparelhos você tem?' })
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return(['CHUNK'])
      anchored_step = nil
      allow(Ai::PromptCompiler).to receive(:compile) { |**kw| anchored_step = kw[:step_index]; 'prompt-stub' }

      convo = deliver('e o wifi pega lá fora?', binding: binding, mode: 'live')

      aggregate_failures do
        expect(Ai::KnowledgeRetriever).to have_received(:retrieve).with(hash_including(kinds: ['produto'])) # buscou antecipado
        expect(anchored_step).to eq(0)                                     # prompt ancorado em Aparelhos, não Planos
        expect(convo.additional_attributes['ai_step_index'].to_i).to eq(0) # NÃO avançou: a coleta continua
      end
    end

    # conv 397: a etapa ATUAL declara sua fonte e VENCE o look-ahead da próxima — foi o look-ahead da
    # etapa seguinte (produto) que roubou o turno da VIABILIDADE (que precisa de documento).
    it 'precedência: etapa ATUAL que declara conhecimento VENCE o look-ahead da próxima' do
      enable_worker!
      dept = create_department
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Viabilidade', 'knowledge' => { 'query' => 'cidades atendidas', 'kinds' => ['documento'] } },
                              { 'name' => 'Planos', 'knowledge' => { 'query' => 'planos e preços', 'kinds' => ['produto'] } },
                              { 'name' => 'Fim' }
                            ])
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'nada', query: '') # etapa 0 sem slot -> não avança
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return(['CHUNK'])

      convo = deliver('minha cidade é X', binding: binding, mode: 'live')

      aggregate_failures do
        expect(Ai::KnowledgeRetriever).to have_received(:retrieve).with(hash_including(kinds: ['documento'], query: 'cidades atendidas'))
        expect(Ai::KnowledgeRetriever).not_to have_received(:retrieve).with(hash_including(kinds: ['produto']))
      end
    end

    # Guarda determinística (conv 397): a etapa declarou fonte e o retrieval voltou VAZIO -> evento +
    # knowledge_gap no prompt (o modelo não deve afirmar sem fonte).
    it 'guarda: etapa declara conhecimento e o retrieval volta VAZIO -> knowledge.declared_empty + knowledge_gap no prompt' do
      enable_worker!
      dept = create_department
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Viabilidade', 'knowledge' => { 'query' => 'cidades atendidas', 'kinds' => ['documento'] } },
                              { 'name' => 'Fim' }
                            ])
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'nada', query: '')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([]) # a fonte declarada não retornou nada
      gap = nil
      allow(Ai::PromptCompiler).to receive(:compile) { |**kw| gap = kw[:knowledge_gap]; 'prompt-stub' }

      convo = deliver('minha cidade é X', binding: binding, mode: 'live')

      aggregate_failures do
        expect(Ai::Event.where(conversation_id: convo.id, event_type: 'knowledge.declared_empty')).to exist
        expect(gap).to be(true)
      end
    end

    it 'declarado com list_all:true propaga list_all ao retriever (trazer todos do tipo)' do
      enable_worker!
      dept = create_department
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Planos',
                                'knowledge' => { 'query' => 'planos e preços', 'kinds' => ['produto'], 'list_all' => true } },
                              { 'name' => 'Fim' }
                            ])
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'nada', query: '')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return(['CHUNK'])

      deliver('ok', binding: binding, mode: 'live')

      expect(Ai::KnowledgeRetriever).to have_received(:retrieve).with(hash_including(kinds: ['produto'], list_all: true))
    end

    it 'declarado SEM list_all propaga list_all:false (default) — consulta dirigida vai por similaridade' do
      enable_worker!
      dept = create_department
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Viabilidade',
                                'knowledge' => { 'query' => 'cidades atendidas', 'kinds' => ['documento'] } },
                              { 'name' => 'Fim' }
                            ])
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'nada', query: '')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return(['CHUNK'])

      deliver('ok', binding: binding, mode: 'live')

      expect(Ai::KnowledgeRetriever).to have_received(:retrieve).with(hash_including(kinds: ['documento'], list_all: false))
    end

    it 'worker roda UMA vez por turno (o track_step REUSA o resultado, sem 2ª chamada)' do
      enable_worker!
      dept = create_department
      dept.create_playbook!(active: true, steps: [
                              { 'name' => 'Nome', 'instructions' => 'Peça e grave o nome_cliente.' }, { 'name' => 'Fim' }
                            ])
      binding = create_binding(mode: 'live')
      stub_judge(status: 'answered', value: 'João', asks_about: 'nada', query: '')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })

      deliver('meu nome é João', binding: binding, mode: 'live')

      expect(Ai::Workers::CaptureJudge).to have_received(:judge).once
    end

    it 'shadow: o worker NÃO roda' do
      enable_worker!
      create_department
      binding = create_binding(mode: 'shadow')
      allow(Ai::Workers::CaptureJudge).to receive(:judge)
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })

      deliver('quero saber dos valores', binding: binding, mode: 'shadow')

      expect(Ai::Workers::CaptureJudge).not_to have_received(:judge)
    end

    it 'dois bindings (agentes distintos) na MESMA mensagem: worker roda UMA vez (idempotência do claim)' do
      enable_worker!
      create_department # agente 1
      b1 = create_binding(mode: 'live')
      # 2º agente + department no MESMO inbox (o índice único proíbe 2 bindings do mesmo agente).
      agent2 = Ai::Agent.create!(account: account, name: 'Bot2', status: 'active', ai_operation_profile_id: profile.id)
      Ai::Department.create!(account: account, ai_agent_id: agent2.id, name: 'Atend2', status: 'active',
                             behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' })
      b2 = Ai::AgentInbox.create!(ai_agent_id: agent2.id, inbox_id: inbox.id, mode: 'live', active: true)
      stub_judge(status: 'not_an_answer', asks_about: 'nada', query: '')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })
      _convo, msg = fresh_message('quero saber dos valores')

      described_class.new(message: msg, agent_inbox: b1, mode: 'live').run
      described_class.new(message: msg, agent_inbox: b2, mode: 'live').run

      expect(Ai::Workers::CaptureJudge).to have_received(:judge).once # o 2º perde o claim atômico
    end

    it 'reexecução do job (mesma mensagem, mesmo binding): worker não roda de novo' do
      enable_worker!
      create_department
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'nada', query: '')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })
      _convo, msg = fresh_message('quero saber dos valores')

      described_class.new(message: msg, agent_inbox: binding, mode: 'live').run
      described_class.new(message: msg, agent_inbox: binding, mode: 'live').run

      expect(Ai::Workers::CaptureJudge).to have_received(:judge).once
    end

    it 'worker FALHOU: busca como hoje (sem filtro) + evento knowledge.fallback' do
      enable_worker!
      create_department
      binding = create_binding(mode: 'live')
      stub_judge(status: 'failed', reason: 'invalid_json')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'ok' })

      convo = deliver('quero saber dos valores', binding: binding, mode: 'live')

      aggregate_failures do
        expect(Ai::KnowledgeRetriever).to have_received(:retrieve).with(hash_including(kinds: nil))
        expect(Ai::Event.where(conversation_id: convo.id, event_type: 'knowledge.fallback')).to exist
        expect(Ai::Event.where(conversation_id: convo.id, event_type: 'knowledge.retrieved').last.payload['source']).to eq('fallback')
      end
    end

    it 'tool_followup recebe o MESMO conhecimento da 1ª chamada (não rebusca)' do
      enable_worker!
      department = create_department
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'contact.read',
                       implementation_type: 'capability', capability_key: 'contact.read', status: 'active')
      binding = create_binding(mode: 'live')
      stub_judge(status: 'not_an_answer', asks_about: 'produto', query: 'planos')
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return(['CHUNK-PRODUTO'])
      stub_decisions(
        { 'decision' => 'invoke_tool', 'tool' => { 'name' => 'contact.read', 'input' => {} } },
        { 'decision' => 'reply', 'reply_text' => 'pronto!' }
      )

      knowledges = []
      allow(Ai::PromptCompiler).to receive(:compile) do |**kwargs|
        knowledges << kwargs[:knowledge]
        'prompt-stub'
      end

      deliver('quais os planos?', binding: binding, mode: 'live')

      expect(knowledges.size).to eq(2)                       # 1ª chamada + followup
      expect(knowledges.last).to eq(['CHUNK-PRODUTO'])       # followup reusa o mesmo bloco
      expect(Ai::KnowledgeRetriever).to have_received(:retrieve).once # buscou uma vez só
    end
  end
end
