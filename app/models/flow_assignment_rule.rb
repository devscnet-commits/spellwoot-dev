# A FlowAssignmentRule decides which OperationalFlow applies to a conversation at closing time.
# predicate is an AND of optional dimensions (role_id, inbox_id, team_id, conversation_origin);
# a missing/blank dimension means "any". Rules are evaluated by ascending priority, first match wins.
class FlowAssignmentRule < ApplicationRecord
  belongs_to :account
  belongs_to :operational_flow

  PREDICATE_KEYS = %w[role_id inbox_id team_id conversation_origin].freeze

  scope :ordered, -> { order(priority: :asc, id: :asc) }

  def matches?(context)
    (predicate || {}).all? do |key, value|
      value.blank? || context[key.to_sym].to_s == value.to_s
    end
  end
end
