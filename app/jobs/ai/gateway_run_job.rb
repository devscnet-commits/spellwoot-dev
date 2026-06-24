# Runs the Gateway for every active agent bound to the message's inbox (shadow + live).
# Mandatory plumbing for the AI runtime (not the optional "shadow" validation feature). The
# binding's mode drives behaviour: shadow records only; live may reply, gated by the department
# reply_scope (off by default, canary for piloting). Background only.
#
# Team routing: when several agents attend the same inbox, only the agent that owns the
# conversation's team replies; the others observe (shadow). Team-less agents attend anything.
class Ai::GatewayRunJob < ApplicationJob
  queue_as :low

  def perform(message_id, grouped: false)
    message = Message.find_by(id: message_id)
    return if message.blank?
    # Debounce: if the customer kept typing, let the newer message's job handle the group.
    return if grouped && !Ai::MessageGrouping.latest_incoming?(message)

    content_override = grouped ? Ai::MessageGrouping.grouped_content(message.conversation) : nil
    conversation_team_id = message.conversation&.team_id
    Ai::AgentInbox.where(inbox_id: message.inbox_id, active: true).includes(:agent).find_each do |binding|
      mode = effective_mode(binding, conversation_team_id)
      Ai::Gateway.new(message: message, agent_inbox: binding, mode: mode, content_override: content_override).run
    end
  end

  private

  def effective_mode(binding, conversation_team_id)
    return binding.mode unless binding.mode == 'live'

    agent_team_id = binding.agent.team_id
    return 'live' if agent_team_id.nil?
    return 'live' if conversation_team_id.present? && conversation_team_id == agent_team_id

    'shadow'
  end
end
