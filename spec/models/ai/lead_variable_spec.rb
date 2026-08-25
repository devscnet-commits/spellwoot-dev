require 'rails_helper'

RSpec.describe Ai::LeadVariable do
  let(:account) { create(:account) }
  let(:agent) do
    profile = Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai',
                                           supervisor_model: 'gpt-4.1-mini')
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end

  def build_var(name)
    agent.lead_variables.create(account: account, name: name, var_type: 'texto')
  end

  # Regra de FORMATO, agnóstica de idioma (não vocabulário): transliteração ASCII + [a-z0-9_], começa por letra.
  describe 'normalização do nome (só on: :create)' do
    it '"número_conta" -> "numero_conta" (transliteração, sem assumir português)' do
      expect(build_var('número_conta').name).to eq('numero_conta')
    end

    it 'espaço/símbolo/barra invertida viram _ e colapsam; apara nas pontas' do
      expect(build_var('  Número da Conta \\sef ').name).to eq('numero_da_conta_sef')
    end

    it 'maiúsculas -> minúsculas' do
      expect(build_var('CPF').name).to eq('cpf')
    end

    it 'só caracteres não-latinos -> normaliza para vazio -> INVÁLIDO (não grava chave vazia)' do
      v = build_var('日本語')
      expect(v).not_to be_persisted
      expect(v.errors[:name]).to be_present
    end
  end

  describe 'validações (on: :create)' do
    it 'deve começar por letra: "2via" é rejeitado' do
      expect(build_var('2via')).not_to be_persisted
    end

    it 'unicidade por AGENTE (case-insensitive), não global' do
      build_var('documento_cpf')
      expect(build_var('Documento_CPF')).not_to be_persisted # normaliza p/ documento_cpf -> colide

      profile2 = Ai::OperationProfile.create!(account_id: account.id, name: 'p2', supervisor_provider: 'openai',
                                              supervisor_model: 'gpt-4.1-mini')
      agent2 = Ai::Agent.create!(account: account, name: 'Bot2', status: 'active', ai_operation_profile_id: profile2.id)
      expect(agent2.lead_variables.create(account: account, name: 'documento_cpf', var_type: 'texto')).to be_persisted
    end

    it 'tamanho máximo (60)' do
      expect(build_var("a#{'b' * 60}")).not_to be_persisted
    end
  end

  describe 'NÃO renomeia as existentes (só on: :create)' do
    it 'editar uma variável fora do padrão NÃO a normaliza (preserva a chave do dado já coletado)' do
      legacy = agent.lead_variables.create!(account: account, name: 'legado')
      # rubocop:disable Rails/SkipsModelValidations -- simula dado LEGADO fora do padrão (bypass proposital)
      legacy.update_column(:name, 'número_conta_ou_cpf_cnpj')
      # rubocop:enable Rails/SkipsModelValidations

      legacy.update!(description: 'editada') # update comum não dispara a normalização

      expect(legacy.reload.name).to eq('número_conta_ou_cpf_cnpj') # intacta
    end
  end
end
