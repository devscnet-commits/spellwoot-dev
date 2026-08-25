require 'rails_helper'

# Aviso proativo de saldo baixo (billing Fase 2): quando plan_credits <= 10% do teto do plano,
# notifica a SCNET UMA vez por ciclo (guardado por low_balance_notified_at).
RSpec.describe 'Ai::Gateway aviso de saldo baixo', type: :model do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:plan) { Plan.create!(name: 'Básico', slug: "basico-#{SecureRandom.hex(4)}", ai_credits_included: 100) }

  before do
    # Criar a subscription auto-cria o AiCreditBalance com plan_credits = plan.ai_credits_included (100).
    Subscription.create!(account: account, plan: plan, status: :active, started_at: Time.current)
    account.enable_features!('ai_core') # depois da subscription (sync de features não mexe no ai_core)
    account.ai_credit_balance.update!(plan_credits: 5, extra_credits: 0) # 5% -> abaixo de 10%

    allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
    allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
    allow(Ai::Workers::MediaProcessor).to receive(:process).and_return(nil)
    agent.update!(behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' })
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'decision' => 'reply', 'reply_text' => 'oi' },
        tokens_in: 1, tokens_out: 1, cost: 0.0, latency_ms: 1, status: 'recorded' }
    )
  end

  def run_gateway
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')
    binding = Ai::AgentInbox.find_by(ai_agent_id: agent.id, inbox_id: inbox.id)
    Ai::Gateway.new(message: message, agent_inbox: binding, mode: 'live').run
    convo
  end

  it 'notifica a SCNET e seta a flag quando o saldo cai a <=10% do teto' do
    expect { run_gateway }
      .to have_enqueued_mail(AdministratorNotifications::CreditRequestMailer, :low_balance_warning)

    expect(account.ai_credit_balance.reload.low_balance_notified_at).to be_present
  end

  it 'NÃO duplica: a 2ª mensagem no mesmo ciclo não reenvia' do
    run_gateway
    clear_enqueued_jobs

    expect { run_gateway }
      .not_to have_enqueued_mail(AdministratorNotifications::CreditRequestMailer, :low_balance_warning)
  end

  it 'NÃO notifica enquanto o saldo está acima de 10%' do
    account.ai_credit_balance.update!(plan_credits: 50) # 50% > 10%

    expect { run_gateway }
      .not_to have_enqueued_mail(AdministratorNotifications::CreditRequestMailer, :low_balance_warning)
  end
end
