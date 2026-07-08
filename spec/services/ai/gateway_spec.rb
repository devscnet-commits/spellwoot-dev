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
  def create_department(behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' }, transfer_rules: {})
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento',
                           status: 'active', behavior: behavior, transfer_rules: transfer_rules)
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
  end

  # === Cenário 5: CLOSE (ao vivo) — resolve a conversa ================================
  context 'close (ao vivo)' do
    it 'resolves the conversation' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'close' })

      convo = deliver('Obrigado, era só isso!', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved knowledge.retrieved
                                         context.assembled decision.made close.executed
                                       ])

      expect(convo.status).to eq('resolved')
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
end
