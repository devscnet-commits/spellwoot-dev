# CRUD for an agent's departments (+ its structured playbook). Nested under ai_agents.
class Api::V1::Accounts::AiDepartmentsController < Api::V1::Accounts::BaseController
  # Keys inside ai_departments.behavior (jsonb) that make up the "Comportamento" tab and are
  # versioned via Ai::Version on each update. base_prompt/guardrails are NOT here — they live on
  # ai_agents and are versioned separately via Ai::Version (versionable=Ai::Agent), no duplication.
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

  # Tipos válidos de automação ao concluir etapa. change_ai_department (Fase 2) fixa o department
  # da conversa via override (validado no DepartmentResolver).
  STEP_AUTOMATION_TYPES = %w[tag webhook change_team update_attribute change_ai_department].freeze

  before_action :set_agent
  before_action :set_department, only: %i[update destroy]

  def index
    departments = @agent.departments.includes(:playbook, :tools, :knowledge_sources).order(:id)
    render json: departments.map { |dept| serialize(dept) }
  end

  def create
    errors = step_automation_errors
    return render(json: { errors: errors }, status: :unprocessable_entity) if errors.present?

    department = @agent.departments.new(scalar_params.merge(account_id: Current.account.id))
    department.assign_attributes(jsonb_params(department))
    return render(json: { errors: department.errors.full_messages }, status: :unprocessable_entity) unless department.save

    ensure_single_default(department)
    upsert_playbook(department)
    render json: serialize(department), status: :created
  end

  def update
    errors = step_automation_errors
    return render(json: { errors: errors }, status: :unprocessable_entity) if errors.present?

    # (1) Concorrência otimista do PLAYBOOK: o save manda o array de steps INTEIRO. Se o cliente carregou
    # ANTES de uma escrita out-of-band (console/outra aba/admin), sobrescrever cego apagaria o campo em
    # silêncio (on_complete/knowledge/list_all/collect/...). lock_version incrementa em TODO update do
    # playbook (inclusive por console). Cliente defasado => 409 (o front recarrega e reaplica), NUNCA
    # sobrescreve. Só barra quando o cliente MANDA um lock_version (edições que tocam o playbook).
    return render(json: { error: 'stale_playbook' }, status: :conflict) if playbook_conflict?

    @department.assign_attributes(scalar_params.merge(jsonb_params(@department)))
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

  # MERGE raso de behavior sobre o valor JÁ PERSISTIDO (department.behavior), não substituição. Achado
  # ao vivo: a aba "Comportamento" só manda os campos de DEPARTMENT_BEHAVIOR_FIELDS (auto_attendance/
  # reply_scope/grouping/max_replies/...) — QUALQUER chave fora desse radar (python_orchestrator, ligada
  # só por rake task, sem UI; vector_store_id, mesmo caso) SUMIA a cada edição pelo painel, porque
  # assign_attributes(behavior: hashify(...)) trocava o hash INTEIRO pelo que o front mandou. department
  # nil em #create (registro novo, nada a preservar) — hashify(nil) já devolve nil e cai fora do merge.
  def jsonb_params(department = nil)
    source = params[:ai_department] || {}
    incoming_behavior = hashify(source[:behavior])
    merged_behavior = incoming_behavior && department ? department.behavior.to_h.merge(incoming_behavior) : incoming_behavior
    {
      sla: hashify(source[:sla]),
      transfer_rules: hashify(source[:transfer_rules]),
      close_rules: hashify(source[:close_rules]),
      behavior: merged_behavior,
      follow_up: hashify(source[:follow_up])
    }.compact
  end

  def hashify(value)
    return nil if value.nil?

    value.respond_to?(:permit!) ? value.permit!.to_h : value
  end

  # true quando o cliente mandou um lock_version defasado em relação ao playbook ATUAL. Sem playbook ainda,
  # ou sem lock_version no payload (save que não toca o playbook), não barra. Ver #update.
  def playbook_conflict?
    current = @department.playbook
    return false if current.nil?

    base = params.dig(:ai_department, :playbook, :lock_version)
    return false if base.blank?

    base.to_i != current.lock_version
  end

  def upsert_playbook(department)
    raw = params.dig(:ai_department, :playbook)
    return if raw.blank?

    data = hashify(raw)
    playbook = department.playbook || department.build_playbook
    playbook.assign_attributes(
      objetivo: data['objetivo'] || department.objetivo,
      steps: merge_step_ids(playbook.steps, data['steps'] || []),
      transfer_when: data['transfer_when'] || [],
      close_when: data['close_when'] || [],
      default_messages: data['default_messages'] || {},
      active: true
    )
    playbook.save!
    ::Ai::Version.snapshot!(playbook, snapshot_fields: ::Ai::Playbook::SNAPSHOT_FIELDS)
  end

  # Frente C / PR1 — merge por id. O array do CLIENTE é autoritário no CONJUNTO e na ORDEM (o lock_version/409
  # garante que ele está atual; step ausente do array = DELETADO, NÃO ressuscitamos órfão do banco). O merge
  # por id serve só para: (a) preservar CAMPOS backend-only dentro de um step CASADO (on_complete/knowledge
  # que o cliente não reenviou — campo com null explícito o cliente APAGA, campo ausente sobrevive); (b) manter
  # o id no round-trip. Step sem id (etapa NOVA) ganha um uuid. Não converte ai_step_index (PR2).
  def merge_step_ids(existing, incoming)
    by_id = index_steps_by_id(existing)
    Array(incoming).map { |raw_step| merge_one_step(raw_step, by_id) }
  end

  def index_steps_by_id(steps)
    Array(steps).each_with_object({}) do |step, acc|
      acc[step['id']] = step if step.is_a?(Hash) && step['id'].present?
    end
  end

  # Um step do cliente: casa por id (preserva campos backend-only do prev), senão é novo; garante um id.
  def merge_one_step(raw_step, by_id)
    step = raw_step.is_a?(Hash) ? raw_step : {}
    prev = step['id'].present? ? by_id[step['id']] : nil
    merged = prev ? prev.merge(step) : step
    merged.merge('id' => merged['id'].presence || SecureRandom.uuid)
  end

  # Valida os automations[] de cada etapa do playbook recebido: rejeita tipo desconhecido ou
  # parâmetro obrigatório faltando. Retorna [] quando válido ou quando não há playbook/steps.
  def step_automation_errors
    raw = params.dig(:ai_department, :playbook, :steps)
    return [] if raw.blank?

    steps = Array(raw).map { |s| s.respond_to?(:to_unsafe_h) ? s.to_unsafe_h : s }.map do |s|
      s.respond_to?(:deep_stringify_keys) ? s.deep_stringify_keys : s
    end

    errors = []
    steps.each_with_index do |step, idx|
      next unless step.is_a?(Hash)

      Array(step['automations']).each do |automation|
        next unless automation.is_a?(Hash)

        type = automation['type'].to_s
        unless STEP_AUTOMATION_TYPES.include?(type)
          errors << "etapa #{idx + 1}: automação com tipo inválido (#{type.presence || 'vazio'})"
          next
        end

        missing = missing_automation_params(type, automation['params'])
        errors << "etapa #{idx + 1}: automação '#{type}' sem parâmetro obrigatório (#{missing.join(', ')})" if missing.present?
      end
    end
    errors
  end

  # Parâmetros obrigatórios por tipo de automação; retorna a lista de faltantes ([] = ok).
  def missing_automation_params(type, params_hash)
    p = (params_hash.is_a?(Hash) ? params_hash : {})
    filled = ->(key) { p[key].to_s.strip.present? }
    case type
    when 'tag' then filled.call('label') ? [] : ['label']
    when 'webhook' then filled.call('url') ? [] : ['url']
    when 'update_attribute' then filled.call('key') ? [] : ['key']
    when 'change_team' then (filled.call('team_id') || filled.call('team_name')) ? [] : ['team_id ou team_name']
    when 'change_ai_department' then filled.call('department_id') ? [] : ['department_id']
    else []
    end
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
