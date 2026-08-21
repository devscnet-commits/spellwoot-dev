# CRUD for AI Agents (the "Agentes IA" config), incluindo o "Comportamento" (behavior jsonb) e o
# playbook estruturado — fusão Departamento -> Agente (19/08): antes eram dois registros (Ai::Agent +
# Ai::Department, 1:1 na prática), agora é um só. Scoped to the current account; ai_* domain only.
class Api::V1::Accounts::AiAgentsController < Api::V1::Accounts::BaseController
  include PlanLimitEnforceable

  # Keys inside ai_agents.behavior (jsonb) that make up the "Comportamento" tab and are
  # versioned via Ai::Version (ai_agent_behavior_versions) on each update. base_prompt/guardrails
  # NOT here — they're plain columns, versionados separadamente via Ai::Agent::SNAPSHOT_FIELDS
  # (ai_agent_versions), sem duplicação.
  BEHAVIOR_FIELDS = %w[
    behavior.auto_attendance
    behavior.reply_scope
    behavior.grouping.delay_seconds
    behavior.max_replies
    behavior.max_input_chars
    behavior.max_input_action
    behavior.max_input_message
  ].freeze

  # Tipos válidos de automação ao concluir etapa.
  STEP_AUTOMATION_TYPES = %w[tag webhook change_team update_attribute].freeze

  before_action :set_agent, only: %i[show update destroy duplicate]
  before_action :validate_plan_ai_agents_limit, only: [:create]

  def index
    agents = ::Ai::Agent.where(account_id: Current.account.id)
                        .includes(:operation_profile, :agent_inboxes)
                        .order(:id)
    render json: agents.map { |agent| serialize_list(agent) }
  end

  def show
    render json: serialize(@agent)
  end

  def create
    agent = ::Ai::Agent.new(agent_params.merge(account_id: Current.account.id))
    agent.assign_attributes(jsonb_params)
    if agent.save
      ::Ai::Version.snapshot!(agent, snapshot_fields: ::Ai::Agent::SNAPSHOT_FIELDS)
      render json: serialize(agent), status: :created
    else
      render json: { errors: agent.errors.full_messages }, status: :unprocessable_entity
    end
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

    @agent.assign_attributes(agent_params.merge(jsonb_params))
    return render(json: { errors: @agent.errors.full_messages }, status: :unprocessable_entity) unless @agent.save

    upsert_playbook
    ::Ai::Version.snapshot!(@agent, snapshot_fields: ::Ai::Agent::SNAPSHOT_FIELDS)
    ::Ai::Version.snapshot!(@agent, snapshot_fields: BEHAVIOR_FIELDS, note: params[:note])
    render json: serialize(@agent)
  end

  def destroy
    @agent.destroy!
    head :no_content
  end

  # Duplica o agente INTEIRO (identidade, comportamento, playbook/etapas, tools, knowledge sources,
  # lead variables, integrações) — pedido do dono da conta (20/08): a cópia manual pelo front (GET +
  # spread + POST) só trazia os campos planos/jsonb do Ai::Agent porque #create nunca chamou
  # #upsert_playbook nem sabia dos registros dependentes (tools/knowledge/lead_variables/integrations
  # vivem em tabelas à parte, referenciadas por ai_agent_id — só existem DEPOIS do agente novo ter um
  # id). Deliberadamente NÃO copia ai_agent_inboxes: a cópia nasce sem nenhuma caixa vinculada (mesmo
  # efeito prático de "todas como não atende" — Ai::AgentInboxesController#show já reporta 'none' pra
  # qualquer inbox sem binding) para nunca colocar duas IAs respondendo a mesma caixa por engano.
  # status sempre 'inactive' na cópia, até o dono revisar e ativar manualmente.
  def duplicate
    copy = nil
    ::Ai::Agent.transaction do
      copy = @agent.dup
      # Achado ao vivo (21/08): a tela mostra assistant_name quando preenchido (AiAgents.vue,
      # AiAgentDetail.vue — {{ agent.assistant_name || agent.name }}), não a coluna "name" — "name" é
      # só o identificador interno (obrigatório, mas sem campo de edição na tela; buildAgentPayload só
      # o preenche na CRIAÇÃO, espelhando assistant_name de então — os dois podem divergir depois se
      # assistant_name for editado). A primeira versão numerava só "name", que a tela nunca mostra —
      # a cópia saía com o MESMO assistant_name do original, parecendo que nada tinha mudado.
      new_name = next_duplicate_name(@agent.assistant_name.presence || @agent.name)
      copy.name = new_name
      copy.assistant_name = new_name if @agent.assistant_name.present?
      copy.status = 'inactive'
      copy.save!

      duplicate_playbook(copy)
      duplicate_has_many(@agent.tools, copy)
      duplicate_has_many(@agent.knowledge_sources, copy) # after_commit da cópia re-ingere os chunks
      duplicate_has_many(@agent.lead_variables, copy)
      duplicate_has_many(@agent.department_integrations, copy)
    end
    ::Ai::Version.snapshot!(copy, snapshot_fields: ::Ai::Agent::SNAPSHOT_FIELDS)
    render json: serialize(copy), status: :created
  end

  private

  # "Nome X" -> "Nome X 1"; duplicar de novo (a partir do original OU de qualquer cópia numerada) ->
  # "Nome X 2", sempre a partir do MAIOR número já usado por esse nome-base na conta (nunca reusa um
  # número already tomado, mesmo se cópias intermediárias forem apagadas/renomeadas fora de ordem).
  # Busca por assistant_name OU name (o display já cai pro fallback name quando assistant_name está
  # vazio — mesmo critério de #duplicate, pra achar duplicatas mesmo que os dois campos tenham
  # divergido num agente editado à mão antes desta correção).
  def next_duplicate_name(base_name)
    base = base_name.to_s.sub(/ \d+\z/, '')
    display_names = ::Ai::Agent.where(account_id: Current.account.id)
                               .where('assistant_name = ? OR assistant_name LIKE ? OR name = ? OR name LIKE ?',
                                      base, "#{base} %", base, "#{base} %")
                               .pluck(:assistant_name, :name)
                               .map { |assistant_name, name| assistant_name.presence || name }
    numbers = display_names.filter_map { |n| n[/\A#{Regexp.escape(base)} (\d+)\z/, 1]&.to_i }
    "#{base} #{(numbers.max || 0) + 1}"
  end

  def duplicate_playbook(copy)
    original = @agent.playbook
    return if original.nil?

    playbook = original.dup
    playbook.ai_agent_id = copy.id
    playbook.lock_version = 0
    playbook.version = 1
    playbook.save!
  end

  def duplicate_has_many(records, copy)
    records.find_each do |record|
      row = record.dup
      row.ai_agent_id = copy.id
      row.save!
    end
  end

  # Limite de agentes IA do plano atual (billing Fase 2). Sem plano/limite => não bloqueia.
  def validate_plan_ai_agents_limit
    count = ::Ai::Agent.where(account_id: Current.account.id).count
    enforce_plan_limit('ai_agents', count, 'Limite de agentes IA do seu plano atingido.')
  end

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:id], account_id: Current.account.id)
    render(json: { error: 'não encontrado' }, status: :not_found) if @agent.nil?
  end

  def agent_params
    params.require(:ai_agent).permit(
      :name, :stage, :status, :category, :assistant_name, :assistant_avatar, :assistant_description,
      :assistant_personality, :assistant_language, :assistant_voice, :base_prompt, :guardrails,
      :ai_operation_profile_id, :company_name, :site, :version, :identify_as, :team_id,
      :fallback_handoff_team_id,
      handoff_team_ids: [], handoff_agent_ids: []
    )
  end

  # MERGE raso de behavior sobre o valor JÁ PERSISTIDO (@agent.behavior), não substituição. Achado ao
  # vivo: a aba "Comportamento" só manda os campos de BEHAVIOR_FIELDS (auto_attendance/reply_scope/
  # grouping/max_replies/...) — QUALQUER chave fora desse radar (python_orchestrator, ligada só por
  # rake task, sem UI; vector_store_id, mesmo caso) SUMIA a cada edição pelo painel, porque
  # assign_attributes(behavior: hashify(...)) trocava o hash INTEIRO pelo que o front mandou.
  def jsonb_params
    source = params[:ai_agent] || {}
    incoming_behavior = hashify(source[:behavior])
    merged_behavior = incoming_behavior && @agent ? @agent.behavior.to_h.merge(incoming_behavior) : incoming_behavior
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
    current = @agent.playbook
    return false if current.nil?

    base = params.dig(:ai_agent, :playbook, :lock_version)
    return false if base.blank?

    base.to_i != current.lock_version
  end

  def upsert_playbook
    raw = params.dig(:ai_agent, :playbook)
    return if raw.blank?

    data = hashify(raw)
    playbook = @agent.playbook || @agent.build_playbook
    playbook.assign_attributes(
      objetivo: data['objetivo'] || playbook.objetivo,
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
    raw = params.dig(:ai_agent, :playbook, :steps)
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
    else []
    end
  end

  def serialize(agent)
    playbook = agent.playbook
    steps = playbook&.steps
    agent.as_json.merge(
      'playbook' => playbook&.as_json,
      'steps_count' => steps.is_a?(Array) ? steps.size : 0,
      'tools_count' => agent.tools.size,
      'knowledge_sources_count' => agent.knowledge_sources.size
    )
  end

  # List row: enrich with the profile name and whether the agent has any live/shadow binding, so the
  # table can show Tipo / Perfil / Status at a glance.
  def serialize_list(agent)
    bindings = agent.agent_inboxes.select(&:active)
    agent.as_json.merge(
      'operation_profile_name' => agent.operation_profile&.name,
      'has_live' => bindings.any? { |b| b.mode == 'live' },
      'has_shadow' => bindings.any? { |b| b.mode == 'shadow' }
    )
  end
end
