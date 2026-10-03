# A conversation got an owner (assignee or team): without a card it enters its pipeline's entry
# stage; a card in an open stage handed to an agent of another pipeline moves to that pipeline's
# entry stage. Enqueued by PipelineCardHandler.
class Pipelines::AutoEnterJob < ApplicationJob
  queue_as :low

  # owner_changed: false for a brand-new conversation — one created from the board ("Novo negócio")
  # is already on the stage its creator picked and stays there.
  def perform(conversation_id, owner_changed: true)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.nil? || closed_card?(conversation)
    return if conversation.pipeline_stage_id.present? && !owner_changed

    flow = target_flow(conversation)
    Pipelines::StageMover.new(conversation: conversation, stage: flow.default_stage, source: 'auto').perform if flow
  end

  private

  # A won/lost card stays where it is whoever takes the conversation.
  def closed_card?(conversation)
    stage = conversation.pipeline_stage
    stage.present? && !stage.stage?
  end

  # The owner's pipeline, when it is one and the card is not already on it.
  def target_flow(conversation)
    flow = Conversations::FlowResolver.new(conversation: conversation).owner_flow
    return unless flow&.active && flow.pipeline?

    flow unless conversation.pipeline_stage&.operational_flow_id == flow.id
  end
end
