# A FlowAssignmentRule decides which OperationalFlow applies to a conversation at closing time.
# Inclusion dimensions (role_id, inbox_id, team_id, conversation_origin) are ANDed; a blank one
# means "any" and a value may be a single id or a list. excluded_inbox_ids subtracts caixas from
# the match (e.g. "all of team X except these"), so a team rule auto-covers new caixas of the team.
# Rules are evaluated by ascending priority, first match wins.
class FlowAssignmentRule < ApplicationRecord
  belongs_to :account
  belongs_to :operational_flow

  PREDICATE_KEYS = %w[role_id inbox_id team_id conversation_origin].freeze

  scope :ordered, -> { order(priority: :asc, id: :asc) }

  def matches?(context)
    inclusion_match?(context) && !excluded?(context)
  end

  private

  def inclusion_match?(context)
    PREDICATE_KEYS.all? do |key|
      value = (predicate || {})[key]
      value.blank? || Array(value).map(&:to_s).include?(context[key.to_sym].to_s)
    end
  end

  def excluded?(context)
    excluded = Array((predicate || {})['excluded_inbox_ids']).map(&:to_s)
    excluded.present? && excluded.include?(context[:inbox_id].to_s)
  end
end
