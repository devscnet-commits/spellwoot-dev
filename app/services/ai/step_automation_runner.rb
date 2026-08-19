# Runs the automations configured on a step when the AI COMPLETES it (step_completed). Triggered by
# Ai::StateManager#track_step on the completion transition. Each automation runs in ISOLATION: a
# failure logs an ai_event and never raises, so one automation failing never blocks the others nor
# breaks the Gateway run.
#
# Audited actions (tag / attribute) go through Ai::ActionDispatcher#execute_action so they inherit
# CapabilityExecution + ai_events + the live/shadow gate for free (and its own rescue → never raises).
# Webhook (external HTTP) and change_team (a plain team_id swap) run directly with their own isolated
# rescue + ai_event. Tipos: tag / webhook / change_team / update_attribute.
class Ai::StepAutomationRunner
  # dispatcher/run: opcionais — ausentes quando chamado de
  # Api::Internal::AiExecuteToolController#fire_step_automations (o caminho Python-only, sem
  # run_record de Gateway). #apply_tag/#update_attribute caem pro Ai::CapabilityRegistry direto
  # nesse caso — mesmo padrão sem auditoria de Ai::CapabilityExecution que as control tools
  # (avancar_etapa/registrar_*) já usam nesse controller.
  def initialize(conversation:, account:, agent:, dispatcher: nil, run: nil)
    @conversation = conversation
    @account = account
    @agent = agent
    @dispatcher = dispatcher
    @run = run
  end

  # step = the completed step (Hash carrying the 'automations' array).
  def run(step)
    Array(step && (step['automations'] || step[:automations])).each do |automation|
      run_one(automation.is_a?(Hash) ? automation.with_indifferent_access : {})
    end
  end

  private

  def run_one(automation)
    type = automation[:type].to_s
    params = (automation[:params].is_a?(Hash) ? automation[:params] : {}).with_indifferent_access
    case type
    when 'tag' then apply_tag(params)
    when 'webhook' then fire_webhook(params)
    when 'change_team' then change_team(params)
    when 'update_attribute' then update_attribute(params)
    else emit('step_automation.skipped', { type: type, reason: 'tipo desconhecido' }, status: 'error')
    end
  rescue StandardError => e
    emit('step_automation.failed', { type: type, error: "#{e.class}: #{e.message}" }, status: 'error')
  end

  # tag e atributo: via ActionDispatcher -> CapabilityRegistry (auditoria + gate live/shadow). O
  # execute_action já faz rescue e emite <label>.failed sem propagar — isolamento de graça.
  def apply_tag(params)
    label = params[:label].to_s.strip
    raise 'label vazio' if label.blank?

    if @dispatcher
      @dispatcher.execute_action('conversation.add_label', { 'label' => label }, @run,
                                 'step_automation.tag', extra: { label: label })
    else
      Ai::CapabilityRegistry.execute('conversation.add_label', conversation: @conversation, input: { 'label' => label })
      emit('step_automation.tag.executed', { label: label })
    end
  end

  def update_attribute(params)
    key = params[:key].to_s.strip
    raise 'key vazio' if key.blank?

    if @dispatcher
      @dispatcher.execute_action('conversation.update_attributes', { key => params[:value] }, @run,
                                 'step_automation.attribute', extra: { key: key })
    else
      Ai::CapabilityRegistry.execute('conversation.update_attributes', conversation: @conversation, input: { key => params[:value] })
      emit('step_automation.attribute.executed', { key: key })
    end
  end

  # webhook: executor HTTP genérico, direto (não passa pelo tool-calling / Ai::Tool).
  def fire_webhook(params)
    result = Ai::WebhookRunner.call(params.to_h, input: webhook_payload)
    emit('step_automation.webhook', { url: params[:url].to_s, status: result['status'] })
  end

  # change_team: troca SÓ a fila (team_id). Não usa a semântica completa de handoff.
  def change_team(params)
    team_id = resolve_team_id(params)
    raise 'time não encontrado' if team_id.blank?

    @conversation.update!(team_id: team_id)
    emit('step_automation.change_team', { team_id: team_id })
  end

  def resolve_team_id(params)
    if params[:team_id].present?
      id = params[:team_id]
      return ::Team.exists?(id: id, account_id: @account.id) ? id : nil
    end

    name = params[:team_name].to_s
    return nil if name.blank?

    # Reusa só a resolução tolerante por nome do coordinator (sem rodar a semântica de handoff).
    Ai::HandoffCoordinator.new(conversation: @conversation, account: @account, agent: @agent, message: nil)
                          .match_team_by_name(name)
  end

  # Contexto mínimo enviado ao webhook de automação de etapa.
  def webhook_payload
    {
      conversation_id: @conversation.display_id,
      contact_id: @conversation.contact_id,
      account_id: @account.id
    }
  end

  def emit(type, payload, status: 'ok')
    Ai::Event.create!(
      account_id: @account.id, conversation_id: @conversation.id,
      ai_run_id: nil, event_type: type, payload: payload, status: status
    )
  end
end
