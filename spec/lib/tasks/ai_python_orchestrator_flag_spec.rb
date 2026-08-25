require 'rails_helper'
require 'rake'

# Substitui o console/rails runner que era a ÚNICA forma de ligar behavior['python_orchestrator']
# (sem UI ainda) — continua opt-in POR agente, nunca um default automático.
#
# NOTA (fusão Departamento -> Agente): lib/tasks/ai.rake ainda invoca Ai::Department.find_by
# (args[:department_id]) nestas duas tasks — a classe Ai::Department foi REMOVIDA do código
# (app/models/ai/department.rb não existe mais), então a task quebra com NameError em runtime.
# Isso é um gap de produção FORA do escopo desta rodada (só specs). Este spec foi migrado para
# o formato agent-based que o restante do domínio já usa (behavior agora é coluna do Ai::Agent),
# antecipando o fix da task — ele só voltará a passar depois que ai.rake for atualizado para
# receber agent_id/Ai::Agent em vez de department_id/Ai::Department.
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
  let!(:agent) do
    Ai::Agent.create!(account: account, name: 'Comercial', status: 'active', ai_operation_profile_id: profile.id,
                      behavior: { 'auto_attendance' => true })
  end
  let(:disable_task) { Rake::Task['ai:disable_python_orchestrator'] }

  after do
    enable_task.reenable
    disable_task.reenable
  end

  describe 'ai:enable_python_orchestrator' do
    it 'liga a flag SÓ para o agente pedido, preservando o resto de behavior' do
      enable_task.invoke(agent.id.to_s)

      expect(agent.reload.behavior).to include('python_orchestrator' => true, 'auto_attendance' => true)
    end

    it 'não afeta outros agentes' do
      other = Ai::Agent.create!(account: account, name: 'Outro', status: 'active', ai_operation_profile_id: profile.id)

      enable_task.invoke(agent.id.to_s)

      expect(other.reload.behavior.to_h['python_orchestrator']).to be_nil
    end

    it 'aborta com mensagem clara se o agente não existe' do
      expect { enable_task.invoke('999999999') }.to raise_error(SystemExit)
    end
  end

  describe 'ai:disable_python_orchestrator' do
    it 'desliga a flag (volta ao caminho legado)' do
      agent.update!(behavior: agent.behavior.merge('python_orchestrator' => true))

      disable_task.invoke(agent.id.to_s)

      expect(agent.reload.behavior['python_orchestrator']).to be(false)
    end
  end
end
