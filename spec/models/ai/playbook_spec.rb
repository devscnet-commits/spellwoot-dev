require 'rails_helper'

# H6 — validação de ESCRITA do on_complete.team_id contra a whitelist do agente (handoff_team_ids).
# Paridade com o fallback (H4) e o match_team_by_name (H2): fora da whitelist rejeita; whitelist vazia
# rejeita (config ausente, não permissão). Restore é isento (rollback). Prova de mutação por nome.
RSpec.describe Ai::Playbook do
  let(:account) { create(:account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:team_in) { create(:team, account: account, name: 'Suporte') }
  let(:team_out) { create(:team, account: account, name: 'Financeiro') } # NÃO na whitelist
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id,
                      handoff_team_ids: [team_in.id])
  end
  let(:department) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active', behavior: {})
  end

  def build_playbook(team_id)
    department.build_playbook(active: true, close_when: [], transfer_when: [], default_messages: {},
                              steps: [{ 'name' => 'Fim', 'on_complete' => { 'action' => 'handoff_human', 'team_id' => team_id } }])
  end

  describe 'on_complete_teams_in_whitelist (H6 escrita)' do
    it 'time DENTRO da whitelist -> salva' do
      playbook = build_playbook(team_in.id)
      expect(playbook.save).to be(true)
    end

    it 'time FORA da whitelist -> rejeita e NÃO persiste' do
      playbook = build_playbook(team_out.id)
      aggregate_failures do
        expect(playbook.save).to be(false)
        expect(playbook.errors[:steps].join).to include(team_out.id.to_s)
        expect(playbook).not_to be_persisted
      end
    end

    it 'whitelist VAZIA -> rejeita (config ausente, não permissão ampla)' do
      agent.update!(handoff_team_ids: [])
      playbook = build_playbook(team_in.id) # id existe, mas a whitelist está vazia
      aggregate_failures do
        expect(playbook.save).to be(false)
        expect(playbook.errors[:steps].join).to include('whitelist vazia')
      end
    end

    it 'on_complete sem team_id (close/handoff_ai) -> não valida, salva' do
      playbook = department.build_playbook(active: true, close_when: [], transfer_when: [], default_messages: {},
                                           steps: [{ 'name' => 'Fim', 'on_complete' => { 'action' => 'close' } }])
      expect(playbook.save).to be(true)
    end

    it 'ISENÇÃO restore: restoring=true pula a validação (rollback de estado já persistido)' do
      # simula o restore: um estado com time fora da whitelist de HOJE não deve ser barrado
      playbook = build_playbook(team_out.id)
      playbook.restoring = true
      expect(playbook.save).to be(true)
    end
  end
end
