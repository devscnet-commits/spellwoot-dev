# CRUD for an agent's departments (+ its structured playbook). Nested under ai_agents.
class Api::V1::Accounts::AiDepartmentsController < Api::V1::Accounts::BaseController
  before_action :set_agent
  before_action :set_department, only: %i[update destroy]

  def index
    render json: @agent.departments.order(:id).map { |dept| serialize(dept) }
  end

  def create
    department = @agent.departments.new(scalar_params.merge(account_id: Current.account.id))
    department.assign_attributes(jsonb_params)
    return render(json: { errors: department.errors.full_messages }, status: :unprocessable_entity) unless department.save

    upsert_playbook(department)
    render json: serialize(department), status: :created
  end

  def update
    @department.assign_attributes(scalar_params.merge(jsonb_params))
    return render(json: { errors: @department.errors.full_messages }, status: :unprocessable_entity) unless @department.save

    upsert_playbook(@department)
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
    params.require(:ai_department).permit(:name, :objetivo, :status)
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
  end

  def serialize(department)
    department.as_json.merge('playbook' => department.playbook&.as_json)
  end
end
