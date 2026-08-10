require 'rails_helper'

# Teto de segurança por etapa (ai_step_turns) no caminho do orquestrador Python: o Gateway é o
# guarda-fio da contagem (Rails), não a IA. Isola o Ai::PythonOrchestratorClient (stub direto do
# método de classe) para testar SÓ o comportamento do Gateway ao redor dele — a montagem do payload
# em si já é coberta por spec/services/ai/python_orchestrator_client_spec.rb.
RSpec.describe Ai::Gateway do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'padrão', supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  # let! — precisa existir no banco ANTES do Ai::DepartmentResolver rodar dentro de #deliver; um
  # `let` preguiçoso nunca referenciado explicitamente nos testes nunca seria criado (o Gateway
  # cairia direto em 'no_department', sem nunca chegar no branch do python_orchestrator).
  let!(:department) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active',
                           behavior: { 'auto_attendance' => true, 'reply_scope' => 'all', 'python_orchestrator' => true },
                           transfer_rules: transfer_rules)
  end
  let(:transfer_rules) { {} }
  let(:binding) { Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true) }

  before do
    account.enable_features!('ai_core')
    allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
    allow(Ai::Workers::MediaProcessor).to receive(:process).and_return(nil)
    allow(Ai::PythonOrchestratorClient).to receive(:process_message).and_return(reply: 'Olá!', response_id: 'resp_1')
  end

  def deliver(content = 'oi')
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: content)
    described_class.new(message: message, agent_inbox: binding, mode: 'live').run
    convo.reload
  end

  it 'incrementa ai_step_turns quando o turno NÃO avança a etapa (ai_step_index igual antes/depois)' do
    convo = deliver

    expect(convo.additional_attributes['ai_step_turns']).to eq(1)
  end

  it 'acumula ao longo de vários turnos sem avanço' do
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    3.times do
      message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')
      described_class.new(message: message, agent_inbox: binding, mode: 'live').run
    end

    expect(convo.reload.additional_attributes['ai_step_turns']).to eq(3)
  end

  it 'NÃO incrementa quando o ai_step_index avançou durante o turno (simulando a tool avancar_etapa chamada mid-loop)' do
    # process_message roda DENTRO da chamada HTTP real ao Python; aqui simulamos o efeito colateral
    # que a chamada de "avancar_etapa" teria (via Api::Internal::AiExecuteToolController) escrevendo
    # o novo índice ANTES de devolver o resultado — o Gateway só vê o "depois".
    allow(Ai::PythonOrchestratorClient).to receive(:process_message) do |conversation:, **|
      conversation.update!(additional_attributes: (conversation.additional_attributes || {}).merge('ai_step_index' => 1, 'ai_step_turns' => 0))
      { reply: 'Olá!', response_id: 'resp_1' }
    end

    convo = deliver

    expect(convo.additional_attributes['ai_step_turns']).to eq(0)
    expect(convo.additional_attributes['ai_step_index']).to eq(1)
  end

  describe 'force_handoff_notice (teto configurado em transfer_rules.stuck_handoff_turns)' do
    let(:transfer_rules) { { 'stuck_handoff_turns' => 2 } }

    it 'false enquanto ai_step_turns não atingiu o limite' do
      deliver

      expect(Ai::PythonOrchestratorClient).to have_received(:process_message).with(hash_including(force_handoff_notice: false))
    end

    it 'true assim que ai_step_turns >= limite, verificado ANTES de chamar o Python' do
      convo = create(:conversation, account: account, inbox: inbox, status: 'open',
                                    additional_attributes: { 'ai_step_turns' => 2 })
      message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')

      described_class.new(message: message, agent_inbox: binding, mode: 'live').run

      expect(Ai::PythonOrchestratorClient).to have_received(:process_message).with(hash_including(force_handoff_notice: true))
    end

    it 'limite 0 desliga o teto (nunca força)' do
      # department.update! (não mutar o hash do `let` em memória) — o Gateway lê o department via uma
      # query NOVA (Ai::DepartmentResolver), então só uma escrita real no banco é visível pra ele.
      department.update!(transfer_rules: { 'stuck_handoff_turns' => 0 })
      convo = create(:conversation, account: account, inbox: inbox, status: 'open',
                                    additional_attributes: { 'ai_step_turns' => 999 })
      message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')

      described_class.new(message: message, agent_inbox: binding, mode: 'live').run

      expect(Ai::PythonOrchestratorClient).to have_received(:process_message).with(hash_including(force_handoff_notice: false))
    end
  end

  it 'em modo shadow, não incrementa ai_step_turns (mesmo gate de @acts_live do resto do Gateway)' do
    shadow_binding = Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'shadow', active: true)
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')

    described_class.new(message: message, agent_inbox: shadow_binding, mode: 'shadow').run

    expect(convo.reload.additional_attributes['ai_step_turns']).to be_nil
  end
end
