require 'rails_helper'

# Pedido do usuário: antes de eliminar o motor legado, listar departments que só funcionam direito
# nele. Os dois gaps reais encontrados (não são de "formato de playbook", são de FUNCIONALIDADE do
# motor Python): provider diferente de OpenAI (client hardcoded), e automações de etapa (nunca
# disparadas pelo branch do Python — Ai::Gateway#run faz `return` antes de chegar em track_step).
RSpec.describe Ai::PythonMigrationAuditor do
  let(:account) { create(:account) }

  def create_department(provider: 'openai', steps: [], behavior: {})
    profile = Ai::OperationProfile.create!(account_id: account.id, name: "perfil-#{SecureRandom.hex(2)}",
                                           supervisor_provider: provider, supervisor_model: 'algum-modelo')
    agent = Ai::Agent.create!(account: account, name: "Bot #{SecureRandom.hex(2)}", status: 'active',
                              ai_operation_profile_id: profile.id)
    department = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: "Dept #{SecureRandom.hex(2)}",
                                        status: 'active', behavior: behavior)
    Ai::Playbook.create!(department: department, steps: steps) if steps.present?
    department
  end

  describe '.non_openai_provider_departments' do
    it 'lista department cujo provider NÃO é openai' do
      dept = create_department(provider: 'anthropic')

      result = described_class.non_openai_provider_departments

      expect(result).to contain_exactly(
        { department_id: dept.id, name: dept.name, account_id: account.id, provider: 'anthropic' }
      )
    end

    it 'NÃO lista department com provider openai' do
      create_department(provider: 'openai')

      expect(described_class.non_openai_provider_departments).to eq([])
    end

    it 'NÃO lista department sem operation_profile (cai no default openai nos dois motores)' do
      agent = Ai::Agent.new(account: account, name: 'Sem perfil', status: 'active')
      agent.save(validate: false) # ai_operation_profile_id é obrigatório na validação; contorna pro teste
      Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Dept sem perfil', status: 'active')

      expect(described_class.non_openai_provider_departments).to eq([])
    end
  end

  describe '.step_automation_departments' do
    it 'lista department com QUALQUER etapa que declara automations' do
      dept = create_department(steps: [
                                 { 'name' => 'Boas-vindas' },
                                 { 'name' => 'Fechamento', 'automations' => [{ 'type' => 'tag', 'params' => { 'label' => 'vip' } }] }
                               ])

      result = described_class.step_automation_departments

      expect(result).to contain_exactly(
        { department_id: dept.id, name: dept.name, account_id: account.id, step_names: ['Fechamento'] }
      )
    end

    it 'NÃO lista department cujas etapas não têm automations' do
      create_department(steps: [{ 'name' => 'Boas-vindas' }])

      expect(described_class.step_automation_departments).to eq([])
    end

    it 'NÃO lista department sem playbook' do
      create_department

      expect(described_class.step_automation_departments).to eq([])
    end
  end

  describe '.engine_split' do
    it 'separa quantos departments já estão no Python vs. ainda no legado' do
      create_department(behavior: { 'python_orchestrator' => true })
      create_department(behavior: { 'python_orchestrator' => false })
      create_department(behavior: {})

      split = described_class.engine_split

      expect(split).to eq(on_python: 1, on_legacy: 2)
    end
  end

  describe '.report' do
    it 'agrega os 3 achados num hash só' do
      report = described_class.report

      expect(report.keys).to contain_exactly(:non_openai_provider, :step_automations, :engine_split)
    end
  end
end
