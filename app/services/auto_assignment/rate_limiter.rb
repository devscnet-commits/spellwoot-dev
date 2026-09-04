class AutoAssignment::RateLimiter
  pattr_initialize [:inbox!, :agent!]

  def within_limit?
    current_count < limit
  end

  def track_assignment(conversation)
    assignment_key = build_assignment_key(conversation.id)
    Redis::Alfred.set(assignment_key, conversation.id.to_s, ex: seconds_until_window_reset)
  end

  def current_count
    pattern = assignment_key_pattern
    Redis::Alfred.keys_count(pattern)
  end

  private

  # Defaults must match the assignment_policies column defaults (100 per 3600s), which is also
  # what the settings screen advertises ("Defaults to 100 per hour"). They used to be 5 per
  # 5 minutes, so an inbox with no assignment policy silently throttled every agent to 5
  # conversations per 5 minutes — during a burst the whole team went "over limit" and the
  # conversations were left unassigned.
  DEFAULT_LIMIT = 100
  DEFAULT_WINDOW = 1.hour.to_i

  def limit
    config&.fair_distribution_limit.present? ? config.fair_distribution_limit.to_i : DEFAULT_LIMIT
  end

  def window
    config&.fair_distribution_window&.to_i || DEFAULT_WINDOW
  end

  # Janela alinhada ao relogio (ex: janela de 1h -> reseta as 8h, 9h, 10h...), nao deslizante por
  # atribuicao. Toda chave de uma mesma janela expira no MESMO instante (o proximo multiplo de
  # `window` segundos desde a epoch), entao a contagem sempre reflete "quantas atribuicoes desde o
  # inicio da janela atual", igual a um contador que zera no relogio fechado.
  def seconds_until_window_reset
    now = Time.zone.now.to_i
    next_reset = ((now / window) + 1) * window
    next_reset - now
  end

  def config
    @config ||= inbox.assignment_policy
  end

  def assignment_key_pattern
    format(Redis::RedisKeys::ASSIGNMENT_KEY_PATTERN, inbox_id: inbox.id, agent_id: agent.id)
  end

  def build_assignment_key(conversation_id)
    format(Redis::RedisKeys::ASSIGNMENT_KEY, inbox_id: inbox.id, agent_id: agent.id, conversation_id: conversation_id)
  end
end
