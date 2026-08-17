require 'rails_helper'

# Golden master do Ai::Gateway com Python como motor ÚNICO — trava o COMPORTAMENTO OBSERVÁVEL dos
# GATES compartilhados (billing/breaker/department/override) que rodam ANTES/DEPOIS da chamada ao
# Python, e o happy-path básico do próprio branch (reply, shadow, erro de provider). O antigo
# dispatch interno da IA (handoff/close/tools/loop/slot via decision_kind) saiu do Gateway junto com
# a eliminação do motor legado — o Python decide e chama os webhooks
# (Api::Internal::AiExecuteToolController) por conta própria. Comportamento específico do branch
# Python (force_handoff_notice, step_turns, skip_vision) fica em gateway_python_orchestrator_spec.rb.
#
# Rodar:  docker compose exec rails bundle exec rspec spec/services/ai/gateway_spec.rb
#
# O LLM é isolado stubando o ÚNICO ponto de chamada do Gateway: Ai::PythonOrchestratorClient.process_message.
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

  # Stuba o único ponto de chamada de LLM do Gateway (o cliente HTTP do orquestrador Python).
  def stub_python(reply: 'ok', conversation_id: 'conv_1')
    allow(Ai::PythonOrchestratorClient).to receive(:process_message).and_return(reply: reply, conversation_id: conversation_id)
  end

  # Mesma forma que Ai::PythonOrchestratorClient#perform devolve em qualquer erro HTTP/timeout/exceção.
  def stub_python_error
    allow(Ai::PythonOrchestratorClient).to receive(:process_message).and_return(reply: nil, conversation_id: nil)
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
      stub_python(reply: 'Olá! Como posso ajudar?')

      convo = deliver('Oi, tudo bem?', binding: binding, mode: 'shadow')

      expect(event_types(convo)).to eq(%w[message.received department.resolved decision.made reply.intended])

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
      stub_python(reply: 'Claro, posso ajudar com isso!')

      convo = deliver('Preciso de ajuda', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[message.received department.resolved decision.made reply.sent])

      expect(convo.messages.outgoing.last&.content).to eq('Claro, posso ajudar com isso!')
      expect(run_for(convo).status).to eq('recorded')
    end
  end

  # === Cenário 2b: CRÉDITO DE IA ESGOTADO (billing Fase 2) ============================
  context 'crédito de IA esgotado (saldo zerado)' do
    it 'não responde: handoff pro humano, nota interna, sem reply.sent nem chamada ao Python' do
      create_department
      binding = create_binding(mode: 'live')
      account.create_ai_credit_balance!(plan_credits: 0, extra_credits: 0)
      stub_python(reply: 'NÃO deveria responder')

      convo = deliver('Preciso de ajuda', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[
                                         message.received department.resolved
                                         handoff.executed handoff.assign_failed handoff.credit_exhausted
                                       ])
      # A IA não respondeu ao cliente (a nota interna é privada); o Python nem foi chamado.
      expect(convo.messages.outgoing.where(private: false).count).to eq(0)
      expect(convo.messages.where(private: true).count).to eq(1)
      expect(Ai::PythonOrchestratorClient).not_to have_received(:process_message)
      expect(convo.additional_attributes['ai_handoff']).to be(true)
      expect(run_for(convo).status).to eq('credit_exhausted')
    end

    it 'conta SEM balance responde normalmente (fail-open)' do
      create_department
      binding = create_binding(mode: 'live')
      stub_python(reply: 'Claro!')

      convo = deliver('oi', binding: binding, mode: 'live')

      expect(event_types(convo)).to include('reply.sent')
      expect(event_types(convo)).not_to include('handoff.credit_exhausted')
    end

    it 'com custom_llm_api_key ativo, pula o enforcement mesmo com saldo zerado' do
      create_department
      binding = create_binding(mode: 'live')
      account.create_ai_credit_balance!(plan_credits: 0, extra_credits: 0)
      account.enable_features!('custom_llm_api_key')
      stub_python(reply: 'Respondo com a chave própria')

      convo = deliver('oi', binding: binding, mode: 'live')

      expect(event_types(convo)).to include('reply.sent')
      expect(event_types(convo)).not_to include('handoff.credit_exhausted')
    end
  end

  # === Cenário 7: NO_DEPARTMENT — encerra cedo (agente sem department ativo) ==========
  context 'sem department resolvido' do
    it 'finalizes early as no_department' do
      binding = create_binding(mode: 'live')
      stub_python(reply: 'nunca chega aqui')

      convo = deliver('Olá', binding: binding, mode: 'live')

      expect(event_types(convo)).to eq(%w[message.received department.resolved])

      expect(run_for(convo).status).to eq('no_department')
      expect(convo.messages.outgoing.count).to eq(0)
      expect(Ai::PythonOrchestratorClient).not_to have_received(:process_message)
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
      stub_python(reply: 'ok')
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
      stub_python(reply: 'ok')

      convo = deliver_with_override('oi', 999_999, binding: binding)

      expect(convo.label_list).to include('department-override-indisponivel')
      expect(run_for(convo).status).to eq('recorded')
      expect(convo.messages.outgoing.count).to eq(1)
    end
  end

  # === Fase 1: erro de PROVEDOR (status error) -> handoff em vez de silêncio ==========
  # Porta o force_provider_handoff pro branch Python (antes só existia no caminho decide() legado) —
  # sem isto, Ai::PythonOrchestratorClient#perform já devolve reply: nil em qualquer erro HTTP/
  # timeout/exceção e action_dispatcher.reply(department, nil) é um no-op silencioso, deixando o
  # cliente sem resposta E sem handoff.
  context 'provider indisponível (status error): transfere com nota privada, sem mensagem ao cliente' do
    it 'erro de provedor -> nota privada + transferência (reason provider_unavailable), NÃO cai no silêncio' do
      create_department
      binding = create_binding(mode: 'live')
      allow(Ai::HandoffSummaryJob).to receive(:perform_later)
      stub_python_error

      convo = deliver('oi', binding: binding, mode: 'live')

      aggregate_failures do
        expect(event_types(convo)).to include('handoff.provider_unavailable')
        expect(Ai::CapabilityExecution.where(conversation_id: convo.id, capability_key: 'conversation.transfer')).to exist
        # NOTA PRIVADA ao atendente com o motivo técnico (o cliente nunca vê)
        note = convo.messages.where(private: true).last
        expect(note).to be_present
        expect(note.content).to include('cota/billing')
        # DECISÃO DE PRODUTO: NENHUMA mensagem automática ao cliente
        expect(convo.messages.outgoing.where(private: false)).to be_empty
        reason = nil
        expect(Ai::HandoffSummaryJob).to have_received(:perform_later) { |_id, r| reason = r }
        expect(reason).to eq('provider_unavailable')
      end
    end

    it 'em SHADOW: erro de provedor apenas registra (não transfere nem escreve nota)' do
      create_department
      binding = create_binding(mode: 'shadow')
      stub_python_error

      convo = deliver('oi', binding: binding, mode: 'shadow')

      aggregate_failures do
        expect(event_types(convo)).not_to include('handoff.provider_unavailable')
        expect(convo.messages.where(private: true)).to be_empty
      end
    end
  end

  # === Fase 2: e-mail aos admins da conta quando o erro de provedor vira handoff ========
  context 'provider indisponível: avisa os admins da conta (throttled)' do
    it 'envia o e-mail no PRIMEIRO provider_error (linguagem de dono, para os admins da conta)' do
      create_department
      binding = create_binding(mode: 'live')
      stub_python_error

      expect { deliver('oi', binding: binding, mode: 'live') }
        .to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :provider_error_handoff)
    end

    it 'NÃO envia um SEGUNDO e-mail dentro da janela (mesma conta+provedor)' do
      create_department
      binding = create_binding(mode: 'live')
      stub_python_error
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect do
        deliver('oi', binding: binding, mode: 'live')
        deliver('olá?', binding: binding, mode: 'live')
      end.to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :provider_error_handoff).once
    end

    it 'envia DE NOVO depois que a janela do throttle expira' do
      create_department
      binding = create_binding(mode: 'live')
      stub_python_error
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
      stub_python_error
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

  # === Fase 3: circuit breaker — com o breaker ABERTO o Gateway pula a chamada e transfere ========
  context 'Fase 3: breaker aberto pula a chamada ao modelo' do
    it 'breaker aberto: NÃO chama o Python, transfere e emite breaker_skipped, SEM novo e-mail' do
      create_department
      binding = create_binding(mode: 'live')
      allow(Ai::HandoffSummaryJob).to receive(:perform_later)
      allow(Ai::PythonOrchestratorClient).to receive(:process_message) # espião — NÃO deve ser chamado com o breaker aberto
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      3.times { Ai::ProviderBreaker.new(account: account, provider: 'openai').record_failure }

      convo = nil
      expect { convo = deliver('oi', binding: binding, mode: 'live') }
        .not_to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :provider_error_handoff)

      aggregate_failures do
        expect(Ai::PythonOrchestratorClient).not_to have_received(:process_message) # PULOU a chamada condenada
        expect(event_types(convo)).to include('provider.breaker_skipped')
        expect(event_types(convo)).to include('handoff.provider_unavailable')
        expect(event_types(convo)).not_to include('decision.made') # nem chegou a decidir
        expect(Ai::CapabilityExecution.where(conversation_id: convo.id, capability_key: 'conversation.transfer')).to exist
      end
    end
  end
end
