require 'rails_helper'

RSpec.describe Ai::OperationProfile do
  let(:account) { create(:account) }

  def build_profile(**attrs)
    described_class.new({ account: account, name: 'perfil', supervisor_provider: 'openai',
                          supervisor_model: 'gpt-4.1-mini', temperature_position: 20 }.merge(attrs))
  end

  # Restrição de SEGURANÇA: Groq só com modelos aprovados (um llama recomendou concorrentes no smoke).
  describe 'validação de modelo Groq aprovado (defesa em profundidade)' do
    it 'aceita groq com o modelo APROVADO (openai/gpt-oss-120b)' do
      expect(build_profile(supervisor_provider: 'groq', supervisor_model: 'openai/gpt-oss-120b')).to be_valid
    end

    it 'REJEITA groq com modelo não aprovado (ex.: llama-3.1-8b-instant)' do
      profile = build_profile(supervisor_provider: 'groq', supervisor_model: 'llama-3.1-8b-instant')

      expect(profile).not_to be_valid
      expect(profile.errors[:supervisor_model].join).to match(/não é um modelo Groq aprovado/)
    end

    it 'REJEITA groq com qualquer outro modelo arbitrário (via API direta)' do
      expect(build_profile(supervisor_provider: 'groq', supervisor_model: 'gpt-4.1-mini')).not_to be_valid
    end

    it 'NÃO afeta outros providers — openai aceita qualquer modelo (texto livre)' do
      expect(build_profile(supervisor_provider: 'openai', supervisor_model: 'qualquer-modelo-x')).to be_valid
    end

    it 'NÃO afeta outros providers — anthropic aceita qualquer modelo' do
      expect(build_profile(supervisor_provider: 'anthropic', supervisor_model: 'claude-qualquer')).to be_valid
    end

    it 'a lista de aprovados contém o gpt-oss-120b' do
      expect(described_class::GROQ_APPROVED_MODELS).to include('openai/gpt-oss-120b')
    end
  end

  # Achado ao vivo (18/08): budget.monthly_usd/on_limit eram salvos mas nunca lidos por ninguém — o
  # campo "Orçamento" da tela era decorativo. Ver Ai::Gateway#run (ponto de uso real).
  describe 'orçamento (teto mensal, somado entre TODOS os agentes que reusam o perfil)' do
    let(:profile) do
      described_class.create!(account: account, name: 'perfil', supervisor_provider: 'openai',
                              supervisor_model: 'gpt-4.1-mini', temperature_position: 20)
    end
    let(:agent_a) { Ai::Agent.create!(account: account, name: 'A', status: 'active', ai_operation_profile_id: profile.id) }
    let(:agent_b) { Ai::Agent.create!(account: account, name: 'B', status: 'active', ai_operation_profile_id: profile.id) }

    it 'soma o custo do mês corrente entre TODOS os agentes que usam este perfil' do
      Ai::Run.create!(account_id: account.id, ai_agent_id: agent_a.id, cost: 3, status: 'recorded')
      Ai::Run.create!(account_id: account.id, ai_agent_id: agent_b.id, cost: 4, status: 'recorded')

      expect(profile.month_to_date_cost).to eq(7.0)
    end

    it 'ignora Ai::Run de MESES anteriores' do
      Ai::Run.create!(account_id: account.id, ai_agent_id: agent_a.id, cost: 99, status: 'recorded',
                      created_at: 2.months.ago)

      expect(profile.month_to_date_cost).to eq(0.0)
    end

    it 'budget_exceeded? é false sem teto configurado (budget vazio), mesmo com gasto alto' do
      Ai::Run.create!(account_id: account.id, ai_agent_id: agent_a.id, cost: 999, status: 'recorded')

      expect(profile.budget_exceeded?).to be(false)
    end

    it 'budget_exceeded? é true quando o gasto do mês bate ou passa o teto' do
      profile.update!(budget: { 'monthly_usd' => 10 })
      Ai::Run.create!(account_id: account.id, ai_agent_id: agent_a.id, cost: 10, status: 'recorded')

      expect(profile.budget_exceeded?).to be(true)
    end

    it 'budget_exceeded? é false quando o gasto do mês ainda não bateu o teto' do
      profile.update!(budget: { 'monthly_usd' => 10 })
      Ai::Run.create!(account_id: account.id, ai_agent_id: agent_a.id, cost: 9.99, status: 'recorded')

      expect(profile.budget_exceeded?).to be(false)
    end

    it 'budget_on_limit cai em "downgrade" (ainda não implementado -> tratado como alert) quando ausente' do
      expect(profile.budget_on_limit).to eq('downgrade')
    end
  end
end
