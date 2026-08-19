require 'rails_helper'

# Item 3 do usuário: identificar (sem apagar) LeadVariables que nenhuma etapa do playbook ATUAL
# referencia mais.
RSpec.describe Ai::LeadVariableOrphanFinder do
  let(:account) { create(:account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'padrão', supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }

  def create_variable(name)
    Ai::LeadVariable.create!(account: account, ai_agent_id: agent.id, name: name)
  end

  describe '.for_agent' do
    it 'variável referenciada no collect de alguma etapa NÃO é órfã' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'CPF', 'collect' => { 'attribute' => 'cpf' } }
      ])
      create_variable('cpf')

      expect(described_class.for_agent(agent)).to be_empty
    end

    it 'variável sem NENHUMA etapa que a referencie é órfã' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'CPF', 'collect' => { 'attribute' => 'cpf' } }
      ])
      orfa = create_variable('endereco_antigo')

      expect(described_class.for_agent(agent)).to contain_exactly(orfa)
    end

    it 'agent sem playbook: TODAS as variáveis são órfãs' do
      v1 = create_variable('a')
      v2 = create_variable('b')

      expect(described_class.for_agent(agent)).to contain_exactly(v1, v2)
    end

    it 'agent sem lead variables: lista vazia, sem erro' do
      Ai::Playbook.create!(agent: agent, steps: [{ 'name' => 'Boas-vindas' }])

      expect(described_class.for_agent(agent)).to eq([])
    end

    it 'etapa com MAIS de um atributo: nenhum dos dois é órfão' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Cidade', 'collect' => { 'attribute' => %w[cidade viabilidade] } }
      ])
      create_variable('cidade')
      create_variable('viabilidade')

      expect(described_class.for_agent(agent)).to be_empty
    end
  end

  describe '.for_account' do
    it 'agrega órfãs de TODOS os agentes da conta' do
      other_profile = Ai::OperationProfile.create!(account_id: account.id, name: 'p2',
                                                    supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
      other_agent = Ai::Agent.create!(account: account, name: 'Suporte', status: 'active',
                                      ai_operation_profile_id: other_profile.id)
      orfa1 = create_variable('orfa_a')
      orfa2 = Ai::LeadVariable.create!(account: account, ai_agent_id: other_agent.id, name: 'orfa_b')

      expect(described_class.for_account(account)).to contain_exactly(orfa1, orfa2)
    end

    it 'NÃO inclui órfãs de OUTRA conta' do
      other_account = create(:account)
      other_profile = Ai::OperationProfile.create!(account_id: other_account.id, name: 'x',
                                                    supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
      other_agent = Ai::Agent.create!(account: other_account, name: 'Outro', status: 'active',
                                      ai_operation_profile_id: other_profile.id)
      Ai::LeadVariable.create!(account: other_account, ai_agent_id: other_agent.id, name: 'nao_deveria_aparecer')
      create_variable('minha_orfa')

      names = described_class.for_account(account).map(&:name)
      expect(names).to contain_exactly('minha_orfa')
    end
  end

  describe '.all' do
    it 'agrega órfãs de TODOS os agentes do sistema' do
      orfa = create_variable('orfa_global')

      expect(described_class.all).to include(orfa)
    end
  end
end
