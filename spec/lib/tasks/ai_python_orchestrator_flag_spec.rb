require 'rails_helper'
require 'rake'

# Substitui o console/rails runner que era a ÚNICA forma de ligar behavior['python_orchestrator']
# (sem UI ainda) — continua opt-in POR department, nunca um default automático.
RSpec.describe 'ai:enable_python_orchestrator / ai:disable_python_orchestrator', type: :task do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('ai:enable_python_orchestrator')
  end

  let(:enable_task) { Rake::Task['ai:enable_python_orchestrator'] }
  let(:account) { create(:account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'padrão',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let!(:department) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Comercial', status: 'active',
                           behavior: { 'auto_attendance' => true })
  end
  let(:disable_task) { Rake::Task['ai:disable_python_orchestrator'] }

  after do
    enable_task.reenable
    disable_task.reenable
  end

  describe 'ai:enable_python_orchestrator' do
    it 'liga a flag SÓ para o department pedido, preservando o resto de behavior' do
      enable_task.invoke(department.id.to_s)

      expect(department.reload.behavior).to include('python_orchestrator' => true, 'auto_attendance' => true)
    end

    it 'não afeta outros departments' do
      other = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Outro', status: 'active')

      enable_task.invoke(department.id.to_s)

      expect(other.reload.behavior.to_h['python_orchestrator']).to be_nil
    end

    it 'aborta com mensagem clara se o department não existe' do
      expect { enable_task.invoke('999999999') }.to raise_error(SystemExit)
    end
  end

  describe 'ai:disable_python_orchestrator' do
    it 'desliga a flag (volta ao caminho legado)' do
      department.update!(behavior: department.behavior.merge('python_orchestrator' => true))

      disable_task.invoke(department.id.to_s)

      expect(department.reload.behavior['python_orchestrator']).to be(false)
    end
  end
end
