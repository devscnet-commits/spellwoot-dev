# Resolves which department handles a message within an already-resolved agent.
# Order: single department -> explicit inbox->department mapping -> classifier (cheap LLM worker)
# -> default department (is_default) -> first candidate. Departments are tried in `position` order.
# Returns [department, method].
class Ai::DepartmentResolver
  # Cheapest model per provider for the routing decision — trivial task, don't burn the supervisor.
  # Keeps the supervisor's provider (so we reuse its configured key), only drops to the cheap model.
  #
  # DELIBERADO: o classificador de departamento NÃO é um worker configurável pelo usuário. Usa o
  # provider do supervisor + o modelo mais barato hardcoded aqui. A chave worker_overrides['classification']
  # do perfil é VESTIGIAL (sobra de uma feature de "flow routing" removida) — NÃO deve ser lida/usada;
  # não confundir com os 4 workers reais expostos na UI (OCR, Summary, Tradução, RAG).
  CHEAP_MODELS = {
    'openai' => 'gpt-4.1-nano',
    'anthropic' => 'claude-3-5-haiku',
    'google' => 'gemini-2.0-flash',
    'gemini' => 'gemini-2.0-flash',
    'openrouter' => 'gpt-4.1-nano'
  }.freeze
  CLASSIFIER_TIMEOUT = 10 # seconds — routing is quick; cut hung calls (falls back to default).

  def self.resolve(agent:, inbox_id:, message_content:)
    departments = agent.departments.active.order(:position, :id).to_a
    return [nil, 'none'] if departments.empty?
    return [departments.first, 'single'] if departments.size == 1

    mapped = departments.select { |d| d.department_inboxes.any? { |di| di.inbox_id == inbox_id } }
    return [mapped.first, 'inbox_mapping'] if mapped.size == 1

    candidates = mapped.presence || departments
    chosen = classify(candidates, message_content, agent)
    return [chosen, 'classifier'] if chosen

    fallback = candidates.find(&:is_default) || departments.find(&:is_default)
    fallback ? [fallback, 'default'] : [candidates.first, 'fallback']
  end

  # Cheap, deterministic classifier: the model replies with the department's INDEX (1..N) or 0 for
  # "none", so we match by exact index instead of a fragile substring of the name.
  def self.classify(departments, message_content, agent)
    provider = agent.operation_profile&.supervisor_provider.presence || 'openai'
    model = CHEAP_MODELS.fetch(provider, 'gpt-4.1-nano')

    raw = Ai::ModelRouter.call_model(
      provider: provider, model: model, system_prompt: numbered_prompt(departments),
      user_message: message_content.to_s, account_id: agent.account_id, timeout: CLASSIFIER_TIMEOUT
    )
    return nil if raw[:status] == 'error'

    # First integer in the reply; 0 / out-of-range / no digit -> nil -> caller falls back to default.
    index = raw[:text].to_s[/\d+/].to_i
    index.between?(1, departments.size) ? departments[index - 1] : nil
  rescue StandardError => e
    Rails.logger.error "[Ai::DepartmentResolver] #{e.class}: #{e.message}"
    nil
  end

  def self.numbered_prompt(departments)
    options = departments.each_with_index.map { |d, i| "#{i + 1}. #{d.name}: #{d.objetivo}" }.join("\n")
    "Classifique a mensagem do cliente no departamento mais adequado.\n" \
      "Departamentos:\n#{options}\n" \
      "Responda APENAS com o número do departamento (1 a #{departments.size}). " \
      'Se nenhum se aplicar, responda 0.'
  end
end
