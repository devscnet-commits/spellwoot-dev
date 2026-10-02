# Executes the actions of a stage automation on a conversation. Inherits the shared conversation
# actions (team/agent/priority/labels/status) from ActionService; each
# action is { action_name:, action_params: { ... } } and runs isolated, so one failure never blocks
# the next. Returns the list of errors ("action: message").
class Pipelines::ActionService < ActionService
  def initialize(automation, conversation)
    super(conversation)
    @automation = automation
    @errors = []
  end

  def perform
    previous_actor = Current.executed_by
    Current.executed_by = @automation
    Array(@automation.actions).each do |action|
      action = action.to_h.with_indifferent_access
      run_action(action[:action_name].to_s, (action[:action_params] || {}).with_indifferent_access)
    end
    @errors
  ensure
    Current.executed_by = previous_actor
  end

  def pipeline_send_message(params)
    send_text(params[:content], private_note: false)
  end

  def pipeline_add_private_note(params)
    send_text(params[:content], private_note: true)
  end

  # WhatsApp template (processed_params: { body: { '1' => 'value' } }), with the rendered text as content.
  def pipeline_send_template(params)
    template = params[:template].to_h.with_indifferent_access
    raise ArgumentError, 'template missing' if template[:name].blank?

    Messages::MessageBuilder.new(nil, @conversation, {
                                   content: params[:content].presence || template[:name],
                                   private: false,
                                   template_params: template,
                                   content_attributes: { pipeline_automation_id: @automation.id }
                                 }).perform
  end

  # POSTs the lead (conversation, contact, custom attributes, pipeline/stage, deal value) as JSON.
  def pipeline_send_webhook(params)
    url = params[:url].to_s.strip
    response = Ai::SafeHttp.request(:post, url, headers: { 'Content-Type' => 'application/json' }, body: webhook_payload.to_json, timeout: 15)
    raise "HTTP #{response.code}" unless response.code.between?(200, 299)
  end

  # Opens a new conversation for the same contact in another inbox (channel), optionally with a message.
  def pipeline_create_conversation(params)
    inbox = @account.inboxes.find(params[:inbox_id])
    contact_inbox = ContactInboxBuilder.new(contact: @conversation.contact, inbox: inbox, source_id: uazapi_source_id(inbox)).perform
    conversation = Conversation.create!(
      account_id: @account.id, inbox_id: inbox.id, contact_id: @conversation.contact_id, contact_inbox_id: contact_inbox.id,
      custom_attributes: @conversation.custom_attributes, team_id: @conversation.team_id, assignee_id: @conversation.assignee_id
    )
    return if params[:content].blank?

    Messages::MessageBuilder.new(nil, conversation, { content: params[:content], private: false,
                                                      content_attributes: { pipeline_automation_id: @automation.id } }).perform
  end

  # Moves the card to another pipeline: the chosen open stage, or that pipeline's entry stage.
  def pipeline_change_pipeline(params)
    flow = @account.operational_flows.find(params[:pipeline_id])
    stage = params[:stage_id].present? ? flow.resolution_states.stages.find(params[:stage_id]) : flow.default_stage
    Pipelines::StageMover.new(conversation: @conversation, stage: stage, source: 'automation').perform
  end

  def pipeline_assign_team(params)
    assign_team([params[:team_id].presence && params[:team_id].to_i])
  end

  def pipeline_assign_agent(params)
    return remove_assigned_agent(nil) if params[:assignee_id].blank?

    assign_agent([params[:assignee_id].to_i])
  end

  def pipeline_change_priority(params)
    change_priority([params[:priority].presence || 'nil'])
  end

  def pipeline_add_label(params)
    add_label(Array(params[:labels]))
  end

  def pipeline_remove_label(params)
    remove_label(Array(params[:labels]))
  end

  # Stage deadline for the card: replaces any previous one; leaving the stage clears it.
  def pipeline_add_sla(params)
    minutes = params[:minutes].to_i
    raise ArgumentError, 'minutes must be positive' unless minutes.positive?

    @conversation.update!(pipeline_sla_due_at: minutes.minutes.from_now)
  end

  def pipeline_remove_sla(_params)
    @conversation.update!(pipeline_sla_due_at: nil)
  end

  def pipeline_change_status(params)
    change_status([params[:status]])
  end

  def pipeline_change_temperature(params)
    @conversation.update!(temperature: params[:temperature].presence)
  end

  def pipeline_ai_followup(params)
    agent = Ai::Agent.find_by!(id: params[:ai_agent_id], account_id: @account.id)
    Pipelines::AiFollowupService.new(conversation: @conversation, agent: agent, prompt: params[:prompt]).perform!
  end

  private

  def run_action(name, params)
    return @errors << "#{name}: unknown action" unless PipelineAutomation::ACTIONS.include?(name)

    @conversation.reload
    public_send("pipeline_#{name}", params)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: @account).capture_exception
    @errors << "#{name}: #{e.message}"
  end

  def send_text(content, private_note:)
    raise ArgumentError, 'message is empty' if content.blank?

    Messages::MessageBuilder.new(nil, @conversation, { content: content, private: private_note,
                                                       content_attributes: { pipeline_automation_id: @automation.id } }).perform
  end

  def uazapi_source_id(inbox)
    return unless inbox.channel_type == 'Channel::Api' && inbox.channel.try(:uazapi_instance_token).present?

    @conversation.contact.phone_number.to_s.delete('+').presence
  end

  def webhook_payload
    flow = @automation.operational_flow
    contact = @conversation.contact
    {
      event: 'pipeline_automation',
      automation: { id: @automation.id, name: @automation.name, trigger: @automation.trigger_type },
      pipeline: { id: flow.id, name: flow.name },
      stage: { id: @conversation.pipeline_stage_id, name: @conversation.pipeline_stage&.display_label },
      deal_value: flow.deal_value(@conversation),
      temperature: @conversation.temperature,
      contact: { id: contact.id, name: contact.name, email: contact.email, phone_number: contact.phone_number,
                 identifier: contact.identifier, additional_attributes: contact.additional_attributes,
                 custom_attributes: contact.custom_attributes },
      conversation: @conversation.webhook_data
    }
  end
end
