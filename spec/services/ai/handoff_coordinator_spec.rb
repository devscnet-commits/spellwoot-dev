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

  describe '#assign_human — sem membro atribuível (visibilidade)' do
    let(:empty_team) { create(:team, account: account) } # criado sem membros

    before { allow(OnlineStatusTracker).to receive(:get_available_users).and_return({}) }

    it 'aplica a tag "sem-agente-disponivel" na conversa' do
      allow(Ai::CapabilityRegistry).to receive(:execute)

      coordinator.assign_human(empty_team.id, reason: 'modelo_pediu_transferencia')

      expect(Ai::CapabilityRegistry).to have_received(:execute)
        .with('conversation.add_label', hash_including(input: { 'label' => 'sem-agente-disponivel' }))
    end

    it 'notifica o admin da conta por e-mail' do
      allow(Ai::CapabilityRegistry).to receive(:execute)

      expect { coordinator.assign_human(empty_team.id, reason: 'loop') }
        .to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :handoff_no_agent_available)
    end

    it 'emite handoff.assign_failed com reason no_assignable_member' do
      allow(Ai::CapabilityRegistry).to receive(:execute)

      coordinator.assign_human(empty_team.id, reason: 'loop')

      event = Ai::Event.where(conversation_id: conversation.id, event_type: 'handoff.assign_failed').last
      expect(event).to be_present
      expect(event.payload['reason']).to eq('no_assignable_member')
      expect(event.status).to eq('error')
    end

    it 'não duplica a notificação para o mesmo time dentro da janela de throttle' do
      allow(Ai::CapabilityRegistry).to receive(:execute)
      # null_store (teste) não persiste; um MemoryStore real exercita o throttle
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      expect do
        coordinator.assign_human(empty_team.id, reason: 'loop')
        described_class.new(conversation: conversation, account: account, agent: agent, message: message)
                       .assign_human(empty_team.id, reason: 'loop')
      end.to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :handoff_no_agent_available).once
    end
  end

  describe '#assign_human — caminho feliz (há membro no time)' do
    let(:team) { create(:team, account: account) }
    let(:member) { create(:inbox_member, inbox: inbox) }

    before do
      create(:account_user, account: account, user: member.user)
      create(:team_member, team: team, user: member.user)
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
    end

    it 'atribui um membro do time e NÃO aplica tag nem notifica' do
      allow(Ai::CapabilityRegistry).to receive(:execute)

      expect { coordinator.assign_human(team.id, reason: 'loop') }
        .not_to have_enqueued_mail(AdministratorNotifications::AccountNotificationMailer, :handoff_no_agent_available)

      expect(conversation.reload.assignee_id).to eq(member.user_id)
      expect(Ai::CapabilityRegistry).not_to have_received(:execute)
        .with('conversation.add_label', hash_including(input: { 'label' => 'sem-agente-disponivel' }))
    end
  end
end
