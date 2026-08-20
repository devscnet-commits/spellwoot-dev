require 'rails_helper'

# Teto de segurança por etapa (ai_step_turns) no caminho do orquestrador Python (motor ÚNICO desde a
# eliminação do legado — não há mais flag por agente): o Gateway é o guarda-fio da contagem
# (Rails), não a IA. Isola o Ai::PythonOrchestratorClient (stub direto do método de classe) para
# testar SÓ o comportamento do Gateway ao redor dele — a montagem do payload em si já é coberta por
# spec/services/ai/python_orchestrator_client_spec.rb.
RSpec.describe Ai::Gateway do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'padrão', supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:transfer_rules) { {} }
  let(:binding) { Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true) }

  before do
    account.enable_features!('ai_core')
    agent.update!(behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' }, transfer_rules: transfer_rules)
    allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
    allow(Ai::Workers::MediaProcessor).to receive(:process).and_return(nil)
    allow(Ai::PythonOrchestratorClient).to receive(:process_message).and_return(reply: 'Olá!', conversation_id: 'conv_1')
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
      { reply: 'Olá!', conversation_id: 'conv_1' }
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

    # Achado ao vivo (13/08, relacionado ao ticket 557): até este patch, atingir o teto só mandava
    # force_handoff_notice:true pro Python — um empurrão de PROMPT que o modelo podia simplesmente
    # ignorar e continuar enrolando (nada no backend impedia isso). Agora é bloqueio de verdade: o
    # Python nem chega a ser chamado, o Gateway transfere direto (mesmo padrão de
    # credit_exhausted?/max_replies_reached? — zero custo, sem depender do modelo "obedecer" nada).
    it 'ai_step_turns >= limite: handoff FORÇADO pelo backend — Python nem é chamado, não é mais só um pedido no prompt' do
      convo = create(:conversation, account: account, inbox: inbox, status: 'open',
                                    additional_attributes: { 'ai_step_turns' => 2 })
      message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')

      described_class.new(message: message, agent_inbox: binding, mode: 'live').run

      expect(Ai::PythonOrchestratorClient).not_to have_received(:process_message)
      # ai_handoff é a MESMA flag que Ai::ReplyPolicy lê pra parar a IA de responder (ver o bug do
      # transferir_humano corrigido antes) — setada de verdade, não só sugerida ao modelo.
      expect(convo.reload.additional_attributes['ai_handoff']).to be true
    end

    it 'limite 0 desliga o teto (nunca força)' do
      # agent.update! (não mutar o hash do `let` em memória) — o Gateway lê o agente via uma
      # query NOVA, então só uma escrita real no banco é visível pra ele.
      agent.update!(transfer_rules: { 'stuck_handoff_turns' => 0 })
      convo = create(:conversation, account: account, inbox: inbox, status: 'open',
                                    additional_attributes: { 'ai_step_turns' => 999 })
      message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')

      described_class.new(message: message, agent_inbox: binding, mode: 'live').run

      expect(Ai::PythonOrchestratorClient).to have_received(:process_message).with(hash_including(force_handoff_notice: false))
    end
  end

  # Migração pro motor Python (17/08) — transfer_rules['min_confidence'] existia na tela desde o motor
  # legado (Ai::HandoffEvaluator) mas nunca teve efeito nenhum no caminho Python (achado ao vivo: o
  # bug real do Pinhalzinho, a IA dizendo "Atendemos sua cidade!" sem NENHUMA fonte real). O Python
  # agora auto-relata "confianca" 0.0-1.0 a cada turno; o Gateway decide o handoff DEPOIS do turno.
  describe 'low_confidence (transfer_rules.min_confidence)' do
    let(:transfer_rules) { { 'min_confidence' => 0.5 } }

    it 'confidence abaixo do mínimo e o modelo NÃO transferiu: handoff forçado, reply NÃO chega ao cliente' do
      allow(Ai::PythonOrchestratorClient).to receive(:process_message)
        .and_return(reply: 'Atendemos sua cidade!', conversation_id: 'conv_1', confidence: 0.2, transferred: false)

      convo = deliver

      expect(convo.additional_attributes['ai_handoff']).to be true
      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'handoff.low_confidence')).to exist
      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'reply.sent')).not_to exist
    end

    it 'confidence abaixo do mínimo mas o PRÓPRIO modelo já transferiu (transferred: true): não duplica o handoff' do
      allow(Ai::PythonOrchestratorClient).to receive(:process_message)
        .and_return(reply: 'Já vou te transferir.', conversation_id: 'conv_1', confidence: 0.1, transferred: true)

      convo = deliver

      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'handoff.low_confidence')).not_to exist
    end

    it 'confidence ACIMA do mínimo: segue o fluxo normal, sem handoff por confiança' do
      allow(Ai::PythonOrchestratorClient).to receive(:process_message)
        .and_return(reply: 'Olá!', conversation_id: 'conv_1', confidence: 0.9, transferred: false)

      convo = deliver

      expect(convo.additional_attributes['ai_handoff']).not_to be true
      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'reply.sent')).to exist
    end

    it 'min_confidence 0 (desligado, default): nunca transfere por confiança, mesmo com confidence baixa' do
      agent.update!(transfer_rules: { 'min_confidence' => 0 })
      allow(Ai::PythonOrchestratorClient).to receive(:process_message)
        .and_return(reply: 'Olá!', conversation_id: 'conv_1', confidence: 0.01, transferred: false)

      convo = deliver

      expect(convo.additional_attributes['ai_handoff']).not_to be true
    end

    it 'confidence ausente (Python não conseguiu parsear o turno): não quebra, não transfere por confiança' do
      allow(Ai::PythonOrchestratorClient).to receive(:process_message)
        .and_return(reply: 'Só um instante, já te retorno!', conversation_id: 'conv_1', confidence: nil, transferred: false)

      convo = deliver

      expect(convo.additional_attributes['ai_handoff']).not_to be true
    end
  end

  # Python é o motor ÚNICO — não existe mais agente "sem python_orchestrator" nem checagem de
  # flag (truthy/string) pra testar; skip_vision é incondicionalmente true pra QUALQUER agente,
  # já que a OpenAI sempre recebe os pixels crus no mesmo turno (ver Ai::PythonOrchestratorClient).
  # Substituem os 3 testes antigos (ligado/string-truthy/sem-flag), que testavam um branch que não
  # existe mais desde a eliminação do motor legado.
  it 'skip_vision é sempre true no MediaProcessor, pra qualquer agente' do
    deliver

    expect(Ai::Workers::MediaProcessor).to have_received(:process).with(anything, anything, skip_vision: true)
  end

  it 'em modo shadow, não incrementa ai_step_turns (mesmo gate de @acts_live do resto do Gateway)' do
    shadow_binding = Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'shadow', active: true)
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')

    described_class.new(message: message, agent_inbox: shadow_binding, mode: 'shadow').run

    expect(convo.reload.additional_attributes['ai_step_turns']).to be_nil
  end

  # BYOK (billing Fase 3): o Python já fez o retry pra chave global internamente (orchestrator.py) —
  # o Gateway só precisa espelhar o que Ai::Gateway#maybe_byok_fallback fazia no caminho legado (tag +
  # cobrança), a partir do sinal byok_fallback que Ai::PythonOrchestratorClient devolve.
  describe 'byok_fallback (chave própria da conta falhou, Python caiu pra chave global)' do
    it 'ao vivo: aplica a tag "chave-propria-falhou" e cobra 1 crédito SCNET ALÉM do uso normal' do
      AiCreditBalance.create!(account_id: account.id, plan_credits: 5) # saldo suficiente pro consume! não engolir por InsufficientCredits
      allow(Ai::PythonOrchestratorClient).to receive(:process_message)
        .and_return(reply: 'Olá!', conversation_id: 'conv_1', byok_fallback: true)
      allow(Ai::CapabilityRegistry).to receive(:execute)

      deliver

      expect(Ai::CapabilityRegistry).to have_received(:execute)
        .with('conversation.add_label', hash_including(input: { 'label' => 'chave-propria-falhou' }))
      # 2 débitos distintos: Ai::ActionDispatcher#reply cobra 1 crédito de USO normal (toda resposta,
      # com ou sem BYOK) + consume_byok_fallback_credit cobra 1 crédito ADICIONAL de PENALIDADE por
      # ter usado a chave global. 5 - 1 - 1 = 3.
      expect(AiCreditBalance.find_by(account_id: account.id).plan_credits).to eq(3)
    end

    it 'byok_fallback false (caso comum): NÃO aplica tag nem cobra crédito' do
      allow(Ai::CapabilityRegistry).to receive(:execute)

      deliver # stub padrão do before já devolve byok_fallback: false implícito (chave ausente)

      expect(Ai::CapabilityRegistry).not_to have_received(:execute).with('conversation.add_label', anything)
      expect(AiCreditBalance.find_by(account_id: account.id)).to be_nil
    end

    it 'em modo shadow, NÃO cobra crédito mesmo com byok_fallback true (mesmo gate de @acts_live)' do
      shadow_binding = Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'shadow', active: true)
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')
      allow(Ai::PythonOrchestratorClient).to receive(:process_message)
        .and_return(reply: 'Olá!', conversation_id: 'conv_1', byok_fallback: true)

      described_class.new(message: message, agent_inbox: shadow_binding, mode: 'shadow').run

      expect(AiCreditBalance.find_by(account_id: account.id)).to be_nil
    end
  end
end
