# Executes a Tool the AI chose. Tools are autonomous: in live mode they run immediately.
# SAFETY:
#   - shadow mode never executes (records 'skipped');
#   - inactive tools never execute (records 'skipped');
#   - every execution is audited (Ai::CapabilityExecution) with rollback data for undo.
class Ai::ToolExecutor
  def initialize(tool:, input:, conversation:, mode:, run: nil, requested_by: 'ai')
    @tool = tool
    @input = input || {}
    @conversation = conversation
    @mode = mode.to_s
    @run = run
    @requested_by = requested_by
    @account = conversation.account
  end

  # Returns the Ai::CapabilityExecution row.
  def perform
    return record('skipped', reason: 'shadow_mode') unless @mode == 'live'
    return record('skipped', reason: 'tool_inactive') unless @tool&.status == 'active'
    return missing_prerequisites_result if missing_prerequisites.present?

    execute_now
  rescue StandardError => e
    Rails.logger.error "[Ai::ToolExecutor] #{e.class}: #{e.message}"
    record('failed', error: "#{e.class}: #{e.message}")
  end

  # Run a previously pending execution after a human approves it.
  def self.approve_and_run(execution, approver_user_id:)
    return execution unless execution.approval_status == 'pending'

    conversation = ::Conversation.find_by(id: execution.conversation_id)
    tool = Ai::Tool.find_by(id: execution.ai_tool_id)
    output, rollback, = run_for(tool, conversation, execution.input)
    execution.update!(status: 'executed', approval_status: 'approved', approved_by_user_id: approver_user_id,
                      output: output, rollback_data: rollback)
    execution
  rescue StandardError => e
    execution.update!(status: 'failed', error: "#{e.class}: #{e.message}")
    execution
  end

  # Dispatches by the tool's implementation type. Returns [output, rollback_data, audit_key].
  def self.run_for(tool, conversation, input)
    case tool&.implementation_type
    when 'webhook'
      [Ai::WebhookRunner.call(tool.webhook_config, input: input), {}, "webhook:#{tool&.id}"]
    when 'integration'
      link = Ai::IntegrationLink.find_by(id: tool.integration_link_id)
      [Ai::IntegrationConnector.call(link, input: input), {}, "integration:#{tool&.integration_link_id}"]
    else
      result = Ai::CapabilityRegistry.execute(tool&.capability_key, conversation: conversation, input: input)
      [result[:output], result[:rollback_data], tool&.capability_key]
    end
  end

  # Undo an executed capability.
  def self.revert(execution)
    return false unless execution.status == 'executed'

    reverted = Ai::CapabilityRegistry.rollback(execution)
    execution.update!(status: 'reverted') if reverted
    reverted
  end

  private

  def execute_now
    output, rollback, key = self.class.run_for(@tool, @conversation, @input)
    build('executed', output: output, rollback_data: rollback, key: key)
  end

  # Backend guardrail for "flexible" tool ordering (Ai::PythonOrchestratorClient exposes ALL of a
  # department's tools every turn instead of gating by playbook step): a tool marked with
  # required_attributes (e.g. gerar_contrato needing endereco) is blocked — not executed — until
  # those attributes exist. The error text is deliberately readable BY THE MODEL: it comes back as
  # this execution's `error`, which the caller (Api::Internal::AiExecuteToolController) returns to
  # Python as the function_call_output, so the AI reads it and asks the customer for what's missing
  # instead of the ordering being enforced by which tools are even offered.
  def missing_prerequisites
    required = Array(@tool&.required_attributes)
    return [] if required.blank?

    collected = collected_attributes
    required.reject { |key| collected[key.to_s].present? }
  end

  # Same merge order Ai::Gateway/Ai::PromptCompiler use for "collected" data: contact-level facts,
  # then this conversation's live facts (freshest), then the custom_attributes mirror.
  def collected_attributes
    (@conversation.contact&.custom_attributes || {})
      .merge(@conversation.additional_attributes&.dig('ai_collected_facts') || {})
      .merge(@conversation.custom_attributes || {})
      .stringify_keys
  end

  def missing_prerequisites_result
    missing = missing_prerequisites
    record('skipped', reason: 'missing_required_attributes',
                       error: "Faltam os dados obrigatórios antes de usar esta ferramenta: #{missing.join(', ')}")
  end

  def record(status, reason: nil, approval: 'not_required', error: nil)
    build(status, output: (reason ? { 'reason' => reason } : {}), approval: approval, error: error)
  end

  def build(status, output: {}, rollback_data: {}, approval: 'not_required', error: nil, key: nil)
    Ai::CapabilityExecution.create!(
      account_id: @account.id,
      conversation_id: @conversation.id,
      ai_tool_id: @tool&.id,
      ai_run_id: @run&.id,
      capability_key: key || @tool&.capability_key || "integration:#{@tool&.integration_link_id}",
      input: @input,
      output: output,
      status: status,
      governance: 'allowed',
      approval_status: approval,
      requested_by: @requested_by,
      rollback_data: rollback_data,
      error: error
    )
  end
end
