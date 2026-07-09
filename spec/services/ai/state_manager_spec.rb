require 'rails_helper'

RSpec.describe Ai::StateManager do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end
  let(:department) do
    dept = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active',
                                  behavior: {})
    dept.create_playbook!(active: true, steps: [
                            { 'name' => 'Coleta',
                              'automations' => [{ 'type' => 'tag', 'params' => { 'label' => 'vip' } }] }
                          ])
    dept
  end
  let(:run) do
    Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                    inbox_id: inbox.id, run_type: 'decision', mode: 'live', status: 'running')
  end
  let(:dispatcher) do
    Ai::ActionDispatcher.new(conversation: conversation, account: account, mode: 'live', acts_live: true)
  end
  subject(:manager) { described_class.new(conversation: conversation, agent: agent) }

  def track(step_completed:, current_step: 'Coleta', with_context: true)
    decision = { 'current_step' => current_step, 'step_completed' => step_completed }
    if with_context
      manager.track_step(department, decision, dispatcher: dispatcher, run: run)
    else
      manager.track_step(department, decision)
    end
  end

  describe '#track_step step-completion trigger' do
    it 'fires the automations once on completion, not on every read of current_step' do
      runner = instance_double(Ai::StepAutomationRunner, run: nil)
      allow(Ai::StepAutomationRunner).to receive(:new).and_return(runner)

      track(step_completed: false) # etapa em andamento -> não dispara
      track(step_completed: true)  # concluiu -> dispara
      track(step_completed: true)  # já concluída -> NÃO dispara de novo

      expect(runner).to have_received(:run).once
    end

    it 'records the completed step in additional_attributes for idempotence' do
      allow_any_instance_of(Ai::StepAutomationRunner).to receive(:run)

      track(step_completed: true)

      expect(conversation.reload.additional_attributes['ai_completed_steps']).to include('Coleta')
    end

    it 'still tracks the current step (grouping delay) even without completion' do
      track(step_completed: false)

      expect(conversation.reload.additional_attributes.dig('ai_step', 'name')).to eq('Coleta')
    end

    it 'does not fire without dispatcher/run (shadow / no context)' do
      expect(Ai::StepAutomationRunner).not_to receive(:new)

      track(step_completed: true, with_context: false)
    end
  end
end
