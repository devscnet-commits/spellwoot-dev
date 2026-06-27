# Resolves which department handles a message within an already-resolved agent.
# Order: single department -> explicit inbox->department mapping -> classifier (cheap LLM worker)
# -> default department (is_default) -> first candidate. Departments are tried in `position` order.
# Returns [department, method].
class Ai::DepartmentResolver
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

  # Cheap classification worker: picks the best department by name/objetivo.
  def self.classify(departments, message_content, agent)
    profile = agent.operation_profile
    provider = profile&.supervisor_provider.presence || 'openai'
    model = profile&.supervisor_model.presence || 'gpt-4.1-mini'

    options = departments.map { |d| "- #{d.name}: #{d.objetivo}" }.join("\n")
    system_prompt = "Classifique a mensagem do cliente no departamento mais adequado.\n" \
                    "Departamentos:\n#{options}\nResponda APENAS com o nome exato do departamento."

    raw = Ai::ModelRouter.call_model(provider: provider, model: model,
                                     system_prompt: system_prompt, user_message: message_content.to_s,
                                     account_id: agent.account_id)
    return nil if raw[:status] == 'error'

    answer = raw[:text].to_s.strip.downcase
    departments.find { |d| answer.include?(d.name.to_s.downcase) }
  rescue StandardError => e
    Rails.logger.error "[Ai::DepartmentResolver] #{e.class}: #{e.message}"
    nil
  end
end
