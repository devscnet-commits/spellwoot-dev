# Runs the Gateway for every active agent bound to the message's inbox (shadow + live).
# The binding's mode drives behaviour: shadow records only; live may reply, gated by the
# department reply_scope (off by default, canary for piloting). Background only.
class Ai::ShadowRunJob < ApplicationJob
  queue_as :low

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return if message.blank?

    Ai::AgentInbox.where(inbox_id: message.inbox_id, active: true).includes(:agent).find_each do |binding|
      Ai::Gateway.new(message: message, agent_inbox: binding).run
    end
  end
end
