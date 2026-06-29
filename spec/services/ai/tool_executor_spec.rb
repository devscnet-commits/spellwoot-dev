require 'rails_helper'

# Integration coverage for the tool engine: a real Ai::Tool resolved to an internal capability,
# executed and audited in Ai::CapabilityExecution. Covers the live/shadow/inactive safety gates.
RSpec.describe Ai::ToolExecutor do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }

  def tool(capability_key, status: 'active')
    Ai::Tool.create!(account: account, name: capability_key, implementation_type: 'capability',
                     capability_key: capability_key, status: status)
  end

  def run(capability_key, mode:, status: 'active')
    described_class.new(tool: tool(capability_key, status: status), input: {},
                        conversation: conversation, mode: mode).perform
  end

  it 'executes a read capability in live mode and audits it' do
    execution = run('contact.read', mode: 'live')

    expect(execution).to be_a(Ai::CapabilityExecution)
    expect(execution.status).to eq('executed')
    expect(execution.capability_key).to eq('contact.read')
    expect(execution.output['id']).to eq(conversation.contact.id)
  end

  it 'executes a mutating capability and records rollback data' do
    execution = run('conversation.resolve', mode: 'live')

    expect(conversation.reload.status).to eq('resolved')
    expect(execution.status).to eq('executed')
    expect(execution.rollback_data.dig('previous', 'status')).to eq('open')
  end

  it 'never executes in shadow mode (records skipped, no mutation)' do
    execution = run('conversation.resolve', mode: 'shadow')

    expect(execution.status).to eq('skipped')
    expect(execution.output['reason']).to eq('shadow_mode')
    expect(conversation.reload.status).to eq('open')
  end

  it 'never executes an inactive tool (records skipped, no mutation)' do
    execution = run('conversation.resolve', mode: 'live', status: 'inactive')

    expect(execution.status).to eq('skipped')
    expect(execution.output['reason']).to eq('tool_inactive')
    expect(conversation.reload.status).to eq('open')
  end
end
