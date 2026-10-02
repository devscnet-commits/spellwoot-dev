# A conversation got a team (or an assignee): if that team follows a pipeline, the card enters the
# pipeline's entry stage. Enqueued by PipelineCardHandler.
class Pipelines::AutoEnterJob < ApplicationJob
  queue_as :low

  def perform(conversation_id)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.nil? || conversation.pipeline_stage_id.present?

    stage = Conversations::FlowResolver.new(conversation: conversation).flow&.default_stage
    Pipelines::StageMover.new(conversation: conversation, stage: stage, source: 'auto').perform if stage
  end
end
