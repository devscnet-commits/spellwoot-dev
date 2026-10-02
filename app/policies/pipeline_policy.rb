# Any member of the account opens the CRM kanban; the cards themselves are filtered by conversation
# access (Conversations::PermissionFilterService / ConversationPolicy#show?).
class PipelinePolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def stage_cards?
    true
  end

  def move?
    true
  end

  def cards?
    true
  end

  # Same audience as the other reports: administrators and team coordinators/managers.
  def report?
    ReportPolicy.new(user_context, record).view?
  end
end
