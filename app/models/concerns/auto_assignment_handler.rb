module AutoAssignmentHandler
  extend ActiveSupport::Concern
  include Events::Types

  included do
    after_save :run_auto_assignment
  end

  private

  def run_auto_assignment
    # Assignment V2: Also trigger assignment when conversation is resolved or snoozed,
    # bypassing the open-only condition so the AssignmentJob can redistribute capacity.
    # Also trigger when team_id changes on a V2 inbox (e.g. an external integration routing
    # a conversation to a team) — AssignmentHandler#find_assignee_from_team deliberately
    # skips assigning in that case so this policy-aware path handles it instead.
    return unless conversation_status_changed_to_open? ||
                  conversation_status_changed_to_resolved_or_snoozed? ||
                  team_assignment_trigger?
    return unless should_run_auto_assignment?

    if inbox.auto_assignment_v2_enabled?
      if team_assignment_trigger?
        # Team-routed conversations (e.g. from an external CRM) can still be pending, not
        # open, so assign this specific conversation now instead of going through the
        # open-only bulk scan the periodic job uses.
        AutoAssignment::AssignmentService.new(inbox: inbox).assign_conversation_now(self)
      else
        AutoAssignment::AssignmentJob.perform_later(inbox_id: inbox.id)
      end
    else
      # Use legacy assignment system
      # If conversation has a team, only consider team members for assignment
      allowed_agent_ids = team_id.present? ? team_member_ids_with_capacity : inbox.member_ids_with_assignment_capacity
      AutoAssignment::AgentAssignmentService.new(conversation: self, allowed_agent_ids: allowed_agent_ids).perform
    end
  end

  def team_assignment_trigger?
    saved_change_to_team_id? && inbox.auto_assignment_v2_enabled?
  end

  def conversation_status_changed_to_resolved_or_snoozed?
    inbox.auto_assignment_v2_enabled? && saved_change_to_status? && (resolved? || snoozed?)
  end

  def team_member_ids_with_capacity
    return [] if team.blank? || team.allow_auto_assign.blank?

    inbox.member_ids_with_assignment_capacity & team.members.ids
  end

  def should_run_auto_assignment?
    return false unless inbox.enable_auto_assignment?
    # Skip auto-assignment outside business hours when working_hours_enabled
    return false if inbox.out_of_office?

    # Assignment V2: Resolved/snoozed conversations still have an assignee, so bypass the
    # assignee-blank check below. The AssignmentJob needs to run to rebalance assignments.
    return true if conversation_status_changed_to_resolved_or_snoozed?

    # run only if assignee is blank or doesn't have access to inbox
    assignee.blank? || inbox.members.exclude?(assignee)
  end
end
