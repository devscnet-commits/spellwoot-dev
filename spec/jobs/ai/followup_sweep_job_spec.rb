require 'rails_helper'

# Unit coverage for the DISPATCHER role of the sweep. After the refactor the sweep does not
# run the follow-up work inline anymore: it selects candidate conversations (open, unassigned,
# quiet for a while, in an inbox with a live AI binding whose account has ai_core) and enqueues
# one Ai::FollowupConversationJob per conversation. The decision helpers moved to the
# per-conversation job (see followup_conversation_job_spec.rb); the end-to-end side effects are
# in followup_sweep_job_integration_spec.rb.
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

  before { account.enable_features!('ai_core') }

  # A quiet, unassigned, open conversation old enough to clear MIN_QUIET.
  def quiet_conversation(quiet_ago: 5.minutes.ago)
    create(:conversation, account: account, inbox: inbox, status: 'open',
                          assignee: nil, last_activity_at: quiet_ago)
  end

  describe '#perform (dispatcher)' do
    # Reativado (17/08) — ver comentário em Ai::FollowupSweepJob#perform: a causa raiz (department
    # errado sem Ai::Run) já foi corrigida em Ai::FollowupConversationJob#resolved_department antes
    # deste kill-switch ser removido.
    it 'enqueues one FollowupConversationJob per eligible quiet conversation' do
      convo_a = quiet_conversation
      convo_b = quiet_conversation

      expect { described_class.new.perform }
        .to have_enqueued_job(Ai::FollowupConversationJob).with(convo_a.id)
        .and have_enqueued_job(Ai::FollowupConversationJob).with(convo_b.id)
    end

    it 'does not enqueue anything for inboxes without ai_core' do
      account.disable_features!('ai_core')
      quiet_conversation

      expect { described_class.new.perform }.not_to have_enqueued_job(Ai::FollowupConversationJob)
    end

    it 'ignores conversations a human already took over (assignee present)' do
      quiet_conversation.update!(assignee: create(:user, account: account, role: :agent))

      expect { described_class.new.perform }.not_to have_enqueued_job(Ai::FollowupConversationJob)
    end

    it 'ignores conversations that are not open' do
      quiet_conversation.update!(status: :resolved)

      expect { described_class.new.perform }.not_to have_enqueued_job(Ai::FollowupConversationJob)
    end

    it 'ignores conversations still within the MIN_QUIET window (too hot)' do
      quiet_conversation(quiet_ago: 10.seconds.ago)

      expect { described_class.new.perform }.not_to have_enqueued_job(Ai::FollowupConversationJob)
    end

    it 'does nothing and does not raise when another sweep holds the lock' do
      quiet_conversation
      allow_any_instance_of(Redis::LockManager).to receive(:lock).and_return(false)

      expect { described_class.new.perform }.not_to have_enqueued_job(Ai::FollowupConversationJob)
    end
  end
end
