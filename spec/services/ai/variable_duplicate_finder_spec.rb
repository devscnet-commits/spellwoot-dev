require 'rails_helper'

# Item 4 do usuário: achou ao vivo plano_escolhido/registrar_plano_escolhido e viabilidade/
# registrar_viabilidade como pares duplicados — o prefixo reservado "registrar_" (do design antigo de
# function-calling) grudou no nome como se fosse parte do dado.
RSpec.describe Ai::VariableDuplicateFinder do
  let(:account) { create(:account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'padrão', supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:department) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Comercial', status: 'active')
  end

  describe '.lead_variable_duplicates' do
    it 'acha o par quando "X" e "registrar_X" existem no MESMO department' do
      base = Ai::LeadVariable.create!(account: account, ai_department_id: department.id, name: 'plano_escolhido')
      dup = Ai::LeadVariable.create!(account: account, ai_department_id: department.id, name: 'registrar_plano_escolhido')

      pairs = described_class.lead_variable_duplicates

      expect(pairs).to contain_exactly(
        { department_id: department.id, base: 'plano_escolhido', base_id: base.id,
          duplicate: 'registrar_plano_escolhido', duplicate_id: dup.id }
      )
    end

    it 'NÃO acha par entre departments DIFERENTES (mesmo com os dois nomes existindo)' do
      other = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Outro', status: 'active')
      Ai::LeadVariable.create!(account: account, ai_department_id: department.id, name: 'viabilidade')
      Ai::LeadVariable.create!(account: account, ai_department_id: other.id, name: 'registrar_viabilidade')

      expect(described_class.lead_variable_duplicates).to be_empty
    end

    it '"registrar_X" sozinha, sem a base "X", NÃO é reportada (não tem com o que duplicar)' do
      Ai::LeadVariable.create!(account: account, ai_department_id: department.id, name: 'registrar_orfa')

      expect(described_class.lead_variable_duplicates).to be_empty
    end

    it 'nomes sem o prefixo reservado nunca aparecem' do
      Ai::LeadVariable.create!(account: account, ai_department_id: department.id, name: 'cidade')
      Ai::LeadVariable.create!(account: account, ai_department_id: department.id, name: 'telefone')

      expect(described_class.lead_variable_duplicates).to be_empty
    end
  end

  describe '.custom_attribute_duplicates' do
    def define(key, model: 'conversation_attribute')
      CustomAttributeDefinition.create!(account: account, attribute_key: key, attribute_display_name: key,
                                        attribute_model: model, attribute_display_type: 'text')
    end

    it 'acha o par dentro do MESMO account_id + attribute_model' do
      base = define('viabilidade')
      dup = define('registrar_viabilidade')

      pairs = described_class.custom_attribute_duplicates

      expect(pairs).to contain_exactly(
        { account_id: account.id, attribute_model: 'conversation_attribute', base: 'viabilidade', base_id: base.id,
          duplicate: 'registrar_viabilidade', duplicate_id: dup.id }
      )
    end

    it 'NÃO cruza attribute_model diferente (conversation vs contact) mesmo na MESMA conta' do
      define('viabilidade', model: 'conversation_attribute')
      define('registrar_viabilidade', model: 'contact_attribute')

      expect(described_class.custom_attribute_duplicates).to be_empty
    end

    it 'NÃO cruza contas diferentes' do
      other_account = create(:account)
      define('viabilidade')
      CustomAttributeDefinition.create!(account: other_account, attribute_key: 'registrar_viabilidade',
                                        attribute_display_name: 'x', attribute_model: 'conversation_attribute',
                                        attribute_display_type: 'text')

      expect(described_class.custom_attribute_duplicates).to be_empty
    end
  end
end
