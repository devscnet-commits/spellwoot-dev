require 'rails_helper'

RSpec.describe Ai::HandoffCoordinator do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: 'open') }
  let(:message) { create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'incoming') }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:coordinator) do
    described_class.new(conversation: conversation, account: account, agent: agent, message: message)
  end

  describe '#assign_human — enqueue do resumo de handoff' do
    it 'enfileira Ai::HandoffSummaryJob com o reason quando o handoff é automático (reason presente)' do
      expect { coordinator.assign_human(nil, reason: 'loop') }
        .to have_enqueued_job(Ai::HandoffSummaryJob).with(conversation.id, 'loop')
    end

    it 'propaga qualquer reason recebido (ex.: credit_exhausted)' do
      expect { coordinator.assign_human(nil, reason: 'credit_exhausted') }
        .to have_enqueued_job(Ai::HandoffSummaryJob).with(conversation.id, 'credit_exhausted')
    end

    it 'NÃO enfileira quando não há reason (handoff não-automático / chamada sem reason)' do
      expect { coordinator.assign_human(nil, reason: nil) }
        .not_to have_enqueued_job(Ai::HandoffSummaryJob)
    end
  end
end
