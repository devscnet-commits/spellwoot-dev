# Runs every active Shadow that observes the resolved conversation's inbox (and whose scope
# matches AI vs human handling) against the transcript. Background only.
class Ai::ShadowEvalJob < ApplicationJob
  queue_as :low

  def perform(conversation_id)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.blank?

    ai_handled = Ai::Run.where(conversation_id: conversation.id, run_type: 'decision').exists?
    Ai::Shadow.active
              .where(account_id: conversation.account_id)
              .joins(:shadow_inboxes)
              .where(ai_shadow_inboxes: { inbox_id: conversation.inbox_id })
              .distinct
              .find_each do |shadow|
      next unless scope_matches?(shadow, ai_handled)

      Ai::ShadowEvaluator.new(shadow: shadow, conversation: conversation).evaluate
    rescue StandardError => e
      Rails.logger.error "[Ai::ShadowEvalJob] shadow=#{shadow.id} conv=#{conversation.id} #{e.class}: #{e.message}"
    end
  end

  private

  def scope_matches?(shadow, ai_handled)
    scope = shadow.scope.to_h
    return true if scope['observe_ai'] != false && ai_handled
    return true if scope['observe_human'] != false && !ai_handled

    false
  end
end
