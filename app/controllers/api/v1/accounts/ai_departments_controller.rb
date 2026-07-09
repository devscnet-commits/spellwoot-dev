# CRUD for an agent's departments (+ its structured playbook). Nested under ai_agents.
class Api::V1::Accounts::AiDepartmentsController < Api::V1::Accounts::BaseController
  # Keys inside ai_departments.behavior (jsonb) that make up the "Comportamento" tab and are
  # versioned via Ai::Version on each update. base_prompt/guardrails are NOT here — they live on
  # ai_agents and are already covered by Ai::AgentVersion (no duplication).
  DEPARTMENT_BEHAVIOR_FIELDS = %w[
    behavior.auto_attendance
    behavior.reply_scope
    behavior.grouping.delay_seconds
    behavior.max_replies
    behavior.max_input_chars
    behavior.max_input_action
    behavior.max_input_message
    behavior.disabled_custom_attributes
  ].freeze

  before_action :set_agent
  before_action :set_department, only: %i[update destroy]

  def index
    departments = @agent.departments.includes(:playbook, :tools, :knowledge_sources).order(:id)
    render json: departments.map { |dept| serialize(dept) }
  end

  def create
    department = @agent.departments.new(scalar_params.merge(account_id: Current.account.id))
    department.assign_attributes(jsonb_params)
    return render(json: { errors: department.errors.full_messages }, status: :unprocessable_entity) unless department.save

    ensure_single_default(department)
    upsert_playbook(department)
    render json: serialize(department), status: :created
  end

  def update
    @department.assign_attributes(scalar_params.merge(jsonb_params))
    return render(json: { errors: @department.errors.full_messages }, status: :unprocessable_entity) unless @department.save

    ensure_single_default(@department)
    upsert_playbook(@department)
    ::Ai::Version.snapshot!(@department, snapshot_fields: DEPARTMENT_BEHAVIOR_FIELDS, note: params[:note])
    render json: serialize(@department)
  end

  def destroy
    @department.destroy!
    head :no_content
  end

  private

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    render(json: { error: 'agente não encontrado' }, status: :not_found) if @agent.nil?
  end

  def set_department
    @department = @agent.departments.find_by(id: params[:id])
    render(json: { error: 'departamento não encontrado' }, status: :not_found) if @department.nil?
  end

  def scalar_params
    params.require(:ai_department).permit(:name, :objetivo, :instructions, :status, :is_default, :position)
  end

  # Only one default department per agent: clear the flag on the others.
  def ensure_single_default(department)
    return unless department.is_default?

    @agent.departments.where.not(id: department.id).where(is_default: true).update_all(is_default: false)
  end

  def jsonb_params
    source = params[:ai_department] || {}
    {
      sla: hashify(source[:sla]),
      transfer_rules: hashify(source[:transfer_rules]),
      close_rules: hashify(source[:close_rules]),
      behavior: hashify(source[:behavior]),
      follow_up: hashify(source[:follow_up])
    }.compact
  end

  def hashify(value)
    return nil if value.nil?

    value.respond_to?(:permit!) ? value.permit!.to_h : value
  end

  def upsert_playbook(department)
    raw = params.dig(:ai_department, :playbook)
    return if raw.blank?

    data = hashify(raw)
    playbook = department.playbook || department.build_playbook
    playbook.assign_attributes(
      objetivo: data['objetivo'] || department.objetivo,
      steps: data['steps'] || [],
      transfer_when: data['transfer_when'] || [],
      close_when: data['close_when'] || [],
      default_messages: data['default_messages'] || {},
      active: true
    )
    playbook.save!
    ::Ai::PlaybookVersion.snapshot!(playbook)
  end

  def serialize(department)
    playbook = department.playbook
    steps = playbook&.steps
    department.as_json.merge(
      'playbook' => playbook&.as_json,
      'steps_count' => steps.is_a?(Array) ? steps.size : 0,
      'tools_count' => department.tools.size,
      'knowledge_sources_count' => department.knowledge_sources.size
    )
  end
end
