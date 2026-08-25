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

  # Backend guardrail da arquitetura "flexível" (Ai::PythonOrchestratorClient expõe TODAS as tools de
  # uma vez, sem gate por etapa): required_attributes bloqueia execução até os dados existirem, com
  # um erro LEGÍVEL PELA IA (não uma exceção) — o modelo lê e pede o dado faltante ao cliente.
  it 'bloqueia a execução quando falta um required_attribute (não muda nada, erro legível pela IA)' do
    gated = tool('conversation.resolve')
    gated.update!(required_attributes: ['endereco'])

    execution = described_class.new(tool: gated, input: {}, conversation: conversation, mode: 'live').perform

    expect(execution.status).to eq('skipped')
    expect(execution.output['reason']).to eq('missing_required_attributes')
    expect(execution.error).to match(/endereco/)
    expect(conversation.reload.status).to eq('open')
  end

  it 'executa normalmente assim que o required_attribute existe em ai_collected_facts' do
    gated = tool('conversation.resolve')
    gated.update!(required_attributes: ['endereco'])
    conversation.update!(additional_attributes: { 'ai_collected_facts' => { 'endereco' => 'Rua X, 123' } })

    execution = described_class.new(tool: gated, input: {}, conversation: conversation, mode: 'live').perform

    expect(execution.status).to eq('executed')
  end

  # Uma Ferramenta do tipo webhook herda o guard SSRF do Ai::WebhookRunner → Ai::SafeHttp: uma URL
  # apontando para rede interna/metadados é rejeitada e auditada como 'failed', sem derrubar o run.
  it 'records a webhook tool with a private/metadata URL as failed (SSRF blocked, no crash)' do
    webhook_tool = Ai::Tool.create!(account: account, name: 'meta', implementation_type: 'webhook',
                                    status: 'active',
                                    webhook_config: { 'url' => 'http://169.254.169.254/latest/meta-data/',
                                                      'method' => 'POST' })
    execution = described_class.new(tool: webhook_tool, input: {}, conversation: conversation,
                                    mode: 'live').perform

    expect(execution.status).to eq('failed')
    expect(execution.error).to match(/bloqueado por segurança/)
  end
end
