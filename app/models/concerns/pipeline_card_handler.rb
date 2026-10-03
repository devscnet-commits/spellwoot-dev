# Keeps a conversation on its pipeline board. The card owner (assignee, else the team) decides the
# pipeline: a conversation enters its pipeline's entry stage once it gets an owner, and follows the
# assignee to another pipeline when handed to an agent of a different one. A won/lost card that is
# reopened inside the inbox's reopen window goes back to the open stage it came from. Runs in jobs so
# the other after_commit callbacks of the triggering save keep their own saved_changes.
module PipelineCardHandler
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_pipeline_sync, on: [:create, :update]
  end

  # Stage deadline set by a pipeline automation: none / on_time / breached ("SLA atrasado").
  def pipeline_sla_status
    return 'none' if pipeline_sla_due_at.nil?

    pipeline_sla_due_at.past? ? 'breached' : 'on_time'
  end

  private

  def enqueue_pipeline_sync
    return if group_chat?

    Pipelines::AutoEnterJob.perform_later(id, owner_changed: !previously_new_record?) if pipeline_owner_changed?
    Pipelines::ReopenJob.perform_later(id) if pipeline_reopened?
  end

  def pipeline_owner_changed?
    return false if team_id.blank? && assignee_id.blank?

    previously_new_record? || saved_change_to_team_id? || saved_change_to_assignee_id?
  end

  # Only a resolved conversation that opens again (reopen window / agent reopening it).
  def pipeline_reopened?
    saved_change_to_status? && open? && pipeline_stage_id.present? && status_before_last_save == 'resolved'
  end
end
