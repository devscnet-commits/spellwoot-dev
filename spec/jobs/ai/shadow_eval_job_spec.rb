require 'rails_helper'

# Integration coverage for the shadow (observer) engine: ShadowEvalJob -> ShadowEvaluator records
# an Ai::Run (shadow_eval) + a 'shadow.evaluated' event and NEVER touches the conversation.
# The model call is stubbed (the engine wiring is what's under test, not the LLM).
RSpec.describe Ai::ShadowEvalJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  let(:model_result) do
    { provider: 'openai', model: 'gpt-4.1-mini',
      decision: { 'resolution' => 'closed', 'confidence' => 0.9, 'issues' => [] },
      tokens_in: 10, tokens_out: 5, cost: 0, latency_ms: 12, status: 'recorded' }
  end

  before do
    allow(Ai::ModelRouter).to receive(:decide).and_return(model_result)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: 'incoming', content: 'Olá, preciso de ajuda')
  end

  def shadow(status: 'active', scope: {})
    record = Ai::Shadow.create!(account: account, name: 'Auditor', status: status, scope: scope)
    Ai::ShadowInbox.create!(ai_shadow_id: record.id, inbox_id: inbox.id)
    record
  end

  def shadow_runs
    Ai::Run.where(conversation_id: conversation.id, run_type: 'shadow_eval')
  end

  it 'evaluates the conversation and records a run + event without replying' do
    shadow
    before_messages = conversation.messages.count

    described_class.new.perform(conversation.id)

    run = shadow_runs.first
    expect(run).to be_present
    expect(run.mode).to eq('shadow')
    expect(run.decision['resolution']).to eq('closed')
    expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'shadow.evaluated')).to exist
    expect(conversation.messages.count).to eq(before_messages) # read-only: nothing sent
  end

  it 'does not evaluate when the shadow is inactive' do
    shadow(status: 'inactive')

    described_class.new.perform(conversation.id)

    expect(shadow_runs).not_to exist
  end

  it 'does not evaluate when no shadow is linked to the inbox' do
    # An active shadow on a different inbox must not observe this conversation.
    other_inbox = create(:inbox, account: account)
    s = Ai::Shadow.create!(account: account, name: 'Outro', status: 'active', scope: {})
    Ai::ShadowInbox.create!(ai_shadow_id: s.id, inbox_id: other_inbox.id)

    described_class.new.perform(conversation.id)

    expect(shadow_runs).not_to exist
  end

  it 'respects scope: skips a human-handled conversation when observe_human is false' do
    shadow(scope: { 'observe_human' => false }) # no decision run => conversation is human-handled

    described_class.new.perform(conversation.id)

    expect(shadow_runs).not_to exist
  end
end
