# "Follow-up IA" of the pipeline: the AI agent chosen for the stage writes one message to resume a
# stalled conversation, following the stage prompt, and the conversation goes back to the AI. The
# handoff is cleared and ai_reactivated_at marks the moment (see Ai::ReplyPolicy): the card owner
# (assignee) is kept and the next human message or handoff hands it back to people. When the agent
# attends this inbox live it is pinned as the one that answers the customer's reply.
class Pipelines::AiFollowupService
  class Error < StandardError; end

  HISTORY_SIZE = 20
  DEFAULT_PROMPT = 'Retome a conversa de onde parou, de forma simpática, e convide o cliente a seguir com o atendimento.'.freeze

  def initialize(conversation:, agent:, prompt: nil, user: nil)
    @conversation = conversation
    @agent = agent
    @prompt = prompt.to_s.strip
    @user = user
    @account = conversation.account
  end

  def perform!
    raise Error, 'ai_unavailable' unless ai_available?
    raise Error, 'credit_exhausted' if credit_exhausted?

    result = Ai::PythonOrchestratorClient.generate_followup(conversation: @conversation, agent: @agent, instruction: instruction)
    persist_openai_conversation(result[:conversation_id])
    record_run(result)
    raise Error, 'generation_failed' if result[:message].blank?

    reactivate!
    Ai::ActionDispatcher.new(conversation: @conversation, account: @account, agent: @agent, mode: 'live', acts_live: true,
                             as_human: @agent.identify_as == 'human').deliver_followup(result[:message])
    create_activity
    result[:message]
  end

  private

  def ai_available?
    return false unless @account.feature_enabled?('ai_core') && @agent.status == 'active'

    !@conversation.group_chat? && !ActiveModel::Type::Boolean.new.cast(@conversation.custom_attributes.to_h['desativa_ia'])
  end

  def credit_exhausted?
    return false if Ai::ModelRouter.account_byok?(@account.id)

    balance = @account.ai_credit_balance
    balance.present? && balance.total <= 0
  end

  def reactivate!
    attrs = @conversation.reload.additional_attributes.to_h.except('ai_handoff')
    attrs['ai_reactivated_at'] = Time.current.iso8601(6)
    attrs['ai_routed_agent_id'] = @agent.id if Ai::AgentInbox.live.exists?(inbox_id: @conversation.inbox_id, ai_agent_id: @agent.id)
    @conversation.update!(additional_attributes: attrs)
  end

  def instruction
    [
      'FOLLOW-UP DO PIPELINE (instrução interna da empresa — não é uma mensagem do cliente).',
      situation,
      ("Etapa do funil: #{@conversation.pipeline_stage.display_label}." if @conversation.pipeline_stage),
      "O que fazer neste follow-up: #{@prompt.presence || DEFAULT_PROMPT}",
      'Escreva somente a mensagem que será enviada agora ao cliente: natural, breve e sem dizer que é automática.',
      "Histórico recente da conversa:\n#{transcript.presence || '(sem mensagens)'}"
    ].compact.join("\n\n")
  end

  def chat_messages
    @chat_messages ||= @conversation.messages.where(message_type: %i[incoming outgoing], private: false)
                                    .reorder(created_at: :desc).limit(HISTORY_SIZE).to_a.reverse
  end

  def situation
    last = chat_messages.last
    return 'A conversa ainda não tem mensagens.' if last.nil?

    elapsed = elapsed_text(Time.current - last.created_at)
    if last.incoming?
      "O cliente mandou a última mensagem há #{elapsed} e ainda não teve resposta da empresa."
    else
      "A empresa mandou a última mensagem há #{elapsed} e o cliente não respondeu."
    end
  end

  def elapsed_text(seconds)
    minutes = (seconds / 60).round
    return "#{minutes} minuto(s)" if minutes < 60
    return "#{minutes / 60} hora(s)" if minutes < 1440

    "#{minutes / 1440} dia(s)"
  end

  def transcript
    chat_messages.map do |message|
      author = message.incoming? ? 'Cliente' : 'Empresa'
      content = message.content.presence || '[anexo]'
      "#{author}: #{content.to_s.truncate(500)}"
    end.join("\n")
  end

  def persist_openai_conversation(conv_id)
    return if conv_id.blank?

    ::Conversation.transaction do
      fresh = ::Conversation.lock.find(@conversation.id)
      attrs = fresh.additional_attributes.to_h
      fresh.update_columns(additional_attributes: attrs.merge('openai_conversation_id' => conv_id)) if attrs['openai_conversation_id'] != conv_id # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def create_activity
    content = I18n.with_locale(@account.locale) do
      if @user.is_a?(User)
        I18n.t('conversations.activity.pipeline.ai_followup', user_name: @user.name, agent_name: @agent.name)
      else
        I18n.t('conversations.activity.pipeline.ai_followup_by_system', agent_name: @agent.name)
      end
    end
    ::Conversations::ActivityMessageJob.perform_later(
      @conversation, { account_id: @account.id, inbox_id: @conversation.inbox_id, message_type: :activity, content: content }
    )
  end

  def record_run(result)
    success = result[:message].present?
    Ai::Run.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_agent_id: @agent.id, inbox_id: @conversation.inbox_id,
      run_type: 'followup', mode: 'live', status: success ? 'completed' : 'error', error_type: (success ? nil : 'provider_error'),
      provider: 'openai', model: result[:model], tokens_in: result[:tokens_in].to_i, tokens_out: result[:tokens_out].to_i,
      cost: Ai::ModelRouter.estimate_cost(result[:model], result[:tokens_in], result[:tokens_out])
    )
  end
end
