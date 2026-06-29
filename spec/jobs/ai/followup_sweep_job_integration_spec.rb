require 'rails_helper'

# Integration coverage for the follow-up engine: real records + real DB side effects
# (messages, ai_events, conversation status). The model is never called on this path.
# Unit coverage for the decision helpers lives in followup_sweep_job_spec.rb.
RSpec.describe Ai::FollowupSweepJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end
  let!(:binding_row) do
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
  end

  before do
    account.enable_features!('ai_core')
    # The follow-up sweep is time-based, not hours-based here; keep the inbox "open" so the
    # inbox_hours context matches deterministically.
    allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
  end

  def create_department(follow_up: {}, close_rules: {})
    Ai::Department.create!(
      account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active',
      behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' },
      follow_up: follow_up, close_rules: close_rules
    )
  end

  # A quiet conversation: the customer wrote, the agent replied, then silence (last is outgoing).
  def quiet_conversation(incoming_ago:, outgoing_ago:)
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    create(:message, account: account, inbox: inbox, conversation: convo,
                     message_type: 'incoming', content: 'Tenho uma dúvida', created_at: incoming_ago)
    create(:message, account: account, inbox: inbox, conversation: convo,
                     message_type: 'outgoing', content: 'Claro, como posso ajudar?', created_at: outgoing_ago)
    convo
  end

  def last_action(convo)
    Ai::Event.find_by(conversation_id: convo.id, event_type: 'followup.action')
  end

  describe 'scheduled attempts (behaviors)' do
    it 'sends the first attempt once its delay has elapsed' do
      create_department(follow_up: {
                          'behaviors' => [{
                            'context' => 'inbox_hours',
                            'attempts' => [{ 'delay_minutes' => 10, 'message' => 'Ainda está por aí?' }],
                            'no_response_action' => 'assign'
                          }]
                        })
      convo = quiet_conversation(incoming_ago: 60.minutes.ago, outgoing_ago: 55.minutes.ago)

      described_class.new.perform

      expect(convo.messages.where(message_type: :outgoing, content: 'Ainda está por aí?')).to exist
      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'followup.sent')).to exist
    end

    it 'does not send before the delay has elapsed' do
      create_department(follow_up: {
                          'behaviors' => [{
                            'context' => 'inbox_hours',
                            'attempts' => [{ 'delay_minutes' => 120, 'message' => 'cedo demais' }],
                            'no_response_action' => 'assign'
                          }]
                        })
      convo = quiet_conversation(incoming_ago: 30.minutes.ago, outgoing_ago: 25.minutes.ago)

      described_class.new.perform

      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'followup.sent')).not_to exist
    end
  end

  describe 'no-follow-up fallback (close_rules.no_followup_actions)' do
    it 'finalizes and sends the close message after the inactivity window' do
      create_department(close_rules: {
                          'message' => 'Encerrando por aqui. Até logo!',
                          'inactivity_minutes' => 30,
                          'no_followup_actions' => ['finalize']
                        })
      convo = quiet_conversation(incoming_ago: 120.minutes.ago, outgoing_ago: 90.minutes.ago)

      described_class.new.perform

      expect(convo.reload.status).to eq('resolved')
      expect(convo.messages.where(content: 'Encerrando por aqui. Até logo!')).to exist
      expect(last_action(convo).payload).to include('action' => 'finalize', 'via' => 'no_followup')
    end

    it 'runs the FIRST action of the list (order = priority)' do
      create_department(close_rules: {
                          'inactivity_minutes' => 30,
                          'no_followup_actions' => %w[transfer_human finalize]
                        })
      convo = quiet_conversation(incoming_ago: 120.minutes.ago, outgoing_ago: 90.minutes.ago)

      described_class.new.perform

      # transfer_human wins (first in the list): it hands off without resolving.
      expect(convo.reload.status).to eq('open')
      expect(last_action(convo).payload).to include('action' => 'transfer_human')
    end

    it 'transfer_ai re-invokes the Gateway on the customer last message' do
      create_department(close_rules: {
                          'inactivity_minutes' => 30, 'no_followup_actions' => ['transfer_ai']
                        })
      convo = quiet_conversation(incoming_ago: 120.minutes.ago, outgoing_ago: 90.minutes.ago)
      last_incoming = convo.messages.incoming.order(:created_at).last

      expect(Ai::GatewayRunJob).to receive(:perform_later).with(last_incoming.id)

      described_class.new.perform

      expect(last_action(convo).payload).to include('action' => 'transfer_ai', 'via' => 'no_followup')
    end

    it 'does not act while still inside the inactivity window' do
      create_department(close_rules: {
                          'inactivity_minutes' => 60, 'no_followup_actions' => ['finalize']
                        })
      convo = quiet_conversation(incoming_ago: 30.minutes.ago, outgoing_ago: 20.minutes.ago)

      described_class.new.perform

      expect(convo.reload.status).to eq('open')
      expect(last_action(convo)).to be_nil
    end

    it 'is idempotent: a second sweep does not act twice in the same silence' do
      create_department(close_rules: {
                          'message' => 'Tchau', 'inactivity_minutes' => 30, 'no_followup_actions' => ['finalize']
                        })
      convo = quiet_conversation(incoming_ago: 120.minutes.ago, outgoing_ago: 90.minutes.ago)

      described_class.new.perform
      described_class.new.perform

      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'followup.action').count).to eq(1)
    end
  end

  describe 'guards' do
    it 'skips a conversation a human already took over' do
      create_department(close_rules: { 'inactivity_minutes' => 1, 'no_followup_actions' => ['finalize'] })
      convo = quiet_conversation(incoming_ago: 120.minutes.ago, outgoing_ago: 90.minutes.ago)
      convo.update!(assignee: create(:user, account: account, role: :agent))

      described_class.new.perform

      expect(convo.reload.status).to eq('open')
      expect(last_action(convo)).to be_nil
    end
  end
end
