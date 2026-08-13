require 'rails_helper'

RSpec.describe Ai::StepAutomationRunner do
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
  let(:run) do
    Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                    inbox_id: inbox.id, run_type: 'decision', mode: 'live', status: 'running')
  end
  let(:dispatcher) do
    Ai::ActionDispatcher.new(conversation: conversation, account: account, mode: 'live', acts_live: true)
  end
  subject(:runner) do
    described_class.new(conversation: conversation, account: account, agent: agent, dispatcher: dispatcher, run: run)
  end

  def step_with(*automations)
    { 'name' => 'Coleta', 'automations' => automations }
  end

  describe 'tag' do
    it 'applies the label via the audited capability (CapabilityExecution + ai_event)' do
      runner.run(step_with({ 'type' => 'tag', 'params' => { 'label' => 'vip' } }))

      expect(conversation.reload.label_list).to include('vip')
      expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'step_automation.tag.executed')).to exist
      expect(Ai::CapabilityExecution.where(conversation_id: conversation.id,
                                           capability_key: 'conversation.add_label')).to exist
    end
  end

  describe 'update_attribute' do
    it 'merges the value into conversation.custom_attributes' do
      conversation.update!(custom_attributes: { 'cidade' => 'Maravilha' })
      runner.run(step_with({ 'type' => 'update_attribute', 'params' => { 'key' => 'etapa', 'value' => 'qualificado' } }))

      expect(conversation.reload.custom_attributes).to include('cidade' => 'Maravilha', 'etapa' => 'qualificado')
    end
  end

  describe 'change_team' do
    let(:team) { create(:team, account: account) }

    it 'moves the conversation to the team by id' do
      runner.run(step_with({ 'type' => 'change_team', 'params' => { 'team_id' => team.id } }))

      expect(conversation.reload.team_id).to eq(team.id)
      expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'step_automation.change_team')).to exist
    end

    it 'resolves the team by name (accent/case insensitive)' do
      team.update!(name: 'Suporte Técnico')
      runner.run(step_with({ 'type' => 'change_team', 'params' => { 'team_name' => 'suporte tecnico' } }))

      expect(conversation.reload.team_id).to eq(team.id)
    end

    it 'emits failed when the team cannot be resolved' do
      runner.run(step_with({ 'type' => 'change_team', 'params' => { 'team_name' => 'inexistente' } }))

      expect(conversation.reload.team_id).to be_nil
      expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'step_automation.failed')).to exist
    end
  end

  describe 'change_ai_department' do
    let(:other_department) do
      Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Vendas', status: 'active', behavior: {})
    end

    it 'writes the department override into additional_attributes (latest wins)' do
      runner.run(step_with({ 'type' => 'change_ai_department', 'params' => { 'department_id' => other_department.id } }))

      expect(conversation.reload.additional_attributes['ai_department_override']).to eq(other_department.id)
      expect(Ai::Event.where(conversation_id: conversation.id,
                             event_type: 'step_automation.change_ai_department')).to exist
    end

    it 'emits failed (isolated) when department_id is missing, without writing an override' do
      runner.run(step_with({ 'type' => 'change_ai_department', 'params' => {} }))

      expect(conversation.reload.additional_attributes['ai_department_override']).to be_nil
      expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'step_automation.failed')).to exist
    end
  end

  describe 'webhook' do
    it 'calls Ai::WebhookRunner directly and emits an event' do
      allow(Ai::WebhookRunner).to receive(:call).and_return({ 'status' => 200 })
      runner.run(step_with({ 'type' => 'webhook', 'params' => { 'url' => 'http://hook', 'method' => 'POST' } }))

      expect(Ai::WebhookRunner).to have_received(:call)
      expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'step_automation.webhook')).to exist
    end
  end

  describe 'isolamento de falha' do
    it 'runs the remaining automations when one raises, without propagating' do
      allow(Ai::WebhookRunner).to receive(:call).and_raise(StandardError, 'boom')

      expect do
        runner.run(step_with(
          { 'type' => 'webhook', 'params' => { 'url' => 'http://hook' } },
          { 'type' => 'tag', 'params' => { 'label' => 'vip' } }
        ))
      end.not_to raise_error

      expect(conversation.reload.label_list).to include('vip')
      expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'step_automation.failed')).to exist
    end

    it 'emits skipped for an unknown automation type' do
      runner.run(step_with({ 'type' => 'nope', 'params' => {} }))

      expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'step_automation.skipped')).to exist
    end
  end
end
