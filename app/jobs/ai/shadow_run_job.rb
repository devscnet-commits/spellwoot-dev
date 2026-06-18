# Runs the shadow Gateway for every shadow agent bound to the message's inbox. Background only.
class Ai::ShadowRunJob < ApplicationJob
  queue_as :low

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return if message.blank?

    Ai::AgentInbox.shadow.where(inbox_id: message.inbox_id).includes(:agent).find_each do |binding|
      Ai::Gateway.new(message: message, agent_inbox: binding).run
    end
  end
end
