require 'rails_helper'

# Achado ao vivo (19/08): "Inativo" no agente (Ai::Agent#status) não desligava nada em tempo real —
# só a própria coluna active/mode do binding é que mandava (Ai::GatewayRunJob, Conversation#
# ai_assistant_active?, Ai::FollowupSweepJob...). Um agente marcado "Inativo" que continuasse com a
# caixa marcada em "Atendimento IA" seguia respondendo o cliente normalmente. agent_active fecha esse
# buraco: as escopes live/shadow agora também exigem o agente estar com status "active".
RSpec.describe Ai::AgentInbox do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai',
                                 supervisor_model: 'gpt-4.1-mini')
  end

  def agent(status:)
    Ai::Agent.create!(account: account, name: 'Maya', status: status, ai_operation_profile_id: profile.id)
  end

  def binding_for(ai_agent, mode:, active: true)
    described_class.create!(ai_agent_id: ai_agent.id, inbox_id: inbox.id, mode: mode, active: active)
  end

  describe '.live' do
    it 'inclui binding live de agente ATIVO' do
      a = agent(status: 'active')
      b = binding_for(a, mode: 'live')

      expect(described_class.live).to include(b)
    end

    it 'EXCLUI binding live de agente INATIVO, mesmo com o binding marcado active/live' do
      a = agent(status: 'inactive')
      b = binding_for(a, mode: 'live')

      expect(described_class.live).not_to include(b)
    end

    it 'continua excluindo binding com active: false (comportamento existente, não mudou)' do
      a = agent(status: 'active')
      b = binding_for(a, mode: 'live', active: false)

      expect(described_class.live).not_to include(b)
    end
  end

  describe '.shadow' do
    it 'EXCLUI binding shadow de agente INATIVO' do
      a = agent(status: 'inactive')
      b = binding_for(a, mode: 'shadow')

      expect(described_class.shadow).not_to include(b)
    end
  end
end
