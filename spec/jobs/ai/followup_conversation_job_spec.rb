require 'rails_helper'

# Unit coverage for the follow-up engine's decision helpers (no DB / HTTP).
# These helpers used to live on Ai::FollowupSweepJob; the dispatcher refactor MOVED them
# (verbatim) to the per-conversation job, so the unit coverage moved with them.
# The full sweep -> per-conversation pipeline is integration-tested in
# followup_sweep_job_integration_spec.rb.
RSpec.describe Ai::FollowupConversationJob do
  let(:job) { described_class.new }

  # BUG FIX: run() usa DepartmentResolver em vez de .departments.active.first.
  # Prova que o departamento CORRETO é resolvido — override e inbox_mapping vencendo .first.
  describe '#run — resolução de departamento via DepartmentResolver' do
    let(:account)      { create(:account) }
    let(:agent)        { create(:ai_agent, account: account) }
    let(:inbox)        { create(:inbox, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, status: 'open', assignee_id: nil) }

    before do
      account.update!(custom_attributes: { 'ai_core' => true }) if account.respond_to?(:custom_attributes)
      allow(account).to receive(:feature_enabled?).with('ai_core').and_return(true)
    end

    it 'usa o departamento indicado por ai_department_override em vez do primeiro' do
      dept_first   = create(:ai_department, agent: agent, follow_up: { 'behaviors' => [{ 'context' => 'inbox_hours', 'attempts' => [{ 'message' => 'vamos seguir?', 'delay_minutes' => 1 }] }] })
      dept_correct = create(:ai_department, agent: agent, follow_up: {})
      conversation.update!(additional_attributes: { 'ai_department_override' => dept_correct.id })
      create(:ai_agent_inbox, agent: agent, inbox: inbox, status: 'live')

      # dept_correct não tem follow-up → job retorna sem enviar mensagem
      expect { job.perform(conversation.id) }.not_to(change { conversation.messages.count })
    end
  end

  describe '#effective_message' do
    it 'reuses the previous non-empty message when the current is blank' do
      attempts = [{ 'message' => 'oi' }, { 'message' => '' }, { 'message' => 'voltei' }]
      expect(job.send(:effective_message, attempts, 1)).to eq('oi')
      expect(job.send(:effective_message, attempts, 2)).to eq('voltei')
    end

    it 'is blank when no message exists up to the index' do
      expect(job.send(:effective_message, [{ 'message' => '' }], 0)).to eq('')
    end
  end

  describe '#active_behavior' do
    let(:behaviors) do
      [{ 'context' => 'inbox_hours' }, { 'context' => 'outside_hours' }]
    end

    it 'picks inbox_hours when the inbox is open' do
      inbox = instance_double(Inbox, available_now?: true)
      expect(job.send(:active_behavior, behaviors, inbox)).to eq(behaviors[0])
    end

    it 'picks outside_hours when the inbox is closed' do
      inbox = instance_double(Inbox, available_now?: false)
      expect(job.send(:active_behavior, behaviors, inbox)).to eq(behaviors[1])
    end

    it 'returns nil when no context matches' do
      inbox = instance_double(Inbox, available_now?: true)
      custom = [{ 'context' => 'outside_hours' }]
      expect(job.send(:active_behavior, custom, inbox)).to be_nil
    end
  end

  describe '#within_custom_window?' do
    let(:inbox) { instance_double(Inbox, timezone: 'UTC') }

    it 'matches a normal daytime window' do
      travel_to(Time.utc(2026, 1, 1, 10, 0)) do
        expect(job.send(:within_custom_window?, [{ 'start' => '08:00', 'end' => '18:00' }], inbox)).to be(true)
        expect(job.send(:within_custom_window?, [{ 'start' => '12:00', 'end' => '18:00' }], inbox)).to be(false)
      end
    end

    it 'matches an overnight window' do
      travel_to(Time.utc(2026, 1, 1, 23, 0)) do
        expect(job.send(:within_custom_window?, [{ 'start' => '20:00', 'end' => '07:00' }], inbox)).to be(true)
      end
    end

    it 'is false when there are no windows' do
      expect(job.send(:within_custom_window?, [], inbox)).to be(false)
    end
  end

  describe '#inactivity_minutes' do
    it 'falls back to the default when unset' do
      expect(job.send(:inactivity_minutes, instance_double(Ai::Department, close_rules: {}))).to eq(30)
    end

    it 'uses the configured value' do
      dept = instance_double(Ai::Department, close_rules: { 'inactivity_minutes' => 15 })
      expect(job.send(:inactivity_minutes, dept)).to eq(15)
    end
  end

  describe '#fallback_actions' do
    it 'reads the ordered no_followup_actions list (order = priority)' do
      dept = instance_double(Ai::Department,
                             close_rules: { 'no_followup_actions' => ['transfer_human', 'finalize'] })
      expect(job.send(:fallback_actions, dept)).to eq(%w[transfer_human finalize])
    end

    it 'drops blanks and is empty when unset' do
      dept = instance_double(Ai::Department, close_rules: { 'no_followup_actions' => ['', 'wait'] })
      expect(job.send(:fallback_actions, dept)).to eq(['wait'])
      expect(job.send(:fallback_actions, instance_double(Ai::Department, close_rules: {}))).to eq([])
    end
  end
end
