# A won/lost card whose conversation was reopened: inside the inbox's reopen window (the same
# setting that reopens a resolved conversation on a new message), the card goes back to the open
# stage it came from and the result is cleared, so the lead is worked again instead of staying closed.
class Pipelines::ReopenJob < ApplicationJob
  queue_as :low

  def perform(conversation_id)
    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation&.open? && closed_card?(conversation)

    target = return_stage(conversation)
    Pipelines::CardMoveService.new(conversation: conversation, stage: target, source: 'auto').perform if target
  end

  private

  def closed_card?(conversation)
    stage = conversation.pipeline_stage
    stage.present? && !stage.stage?
  end

  # The open stage the card left for the closing column (the pipeline's entry stage as a fallback).
  def return_stage(conversation)
    closed_event = closing_event_within_window(conversation)
    return if closed_event.nil?

    closed_event.from_stage&.stage? ? closed_event.from_stage : conversation.pipeline_stage.operational_flow.default_stage
  end

  # The move into the closing column, when the inbox reopens conversations and it happened inside
  # that window.
  def closing_event_within_window(conversation)
    hours = conversation.inbox.reopen_window_hours.to_i
    return if hours <= 0

    event = conversation.stage_events.where(to_stage_id: conversation.pipeline_stage_id).order(created_at: :desc).first
    event if event && event.created_at >= hours.hours.ago
  end
end
