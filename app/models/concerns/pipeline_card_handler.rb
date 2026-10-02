# Puts a conversation on its pipeline board: once its team (or the assignee's team) follows a flow
# with open stages, the card enters that flow's entry stage. Runs in a job so the other after_commit
# callbacks of the triggering save keep their own saved_changes.
module PipelineCardHandler
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_pipeline_entry, on: [:create, :update]
  end

  # Stage deadline set by a pipeline automation: none / on_time / breached ("SLA atrasado").
  def pipeline_sla_status
    return 'none' if pipeline_sla_due_at.nil?

    pipeline_sla_due_at.past? ? 'breached' : 'on_time'
  end

  private

  def enqueue_pipeline_entry
    Pipelines::AutoEnterJob.perform_later(id) if pipeline_entry_candidate? && pipeline_owner_changed?
  end

  def pipeline_entry_candidate?
    pipeline_stage_id.nil? && !group_chat? && (team_id.present? || assignee_id.present?)
  end

  def pipeline_owner_changed?
    previously_new_record? || saved_change_to_team_id? || saved_change_to_assignee_id?
  end
end
