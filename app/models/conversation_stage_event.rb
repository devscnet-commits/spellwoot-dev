# One pipeline stage change of a conversation (kanban card). source tells who moved it:
# manual (drag on the board), result (won/lost picked in the conversation), automation, auto
# (entered the pipeline through its team) or backfill.
# == Schema Information
#
# Table name: conversation_stage_events
#
#  id                  :bigint           not null, primary key
#  source              :string           default("manual"), not null
#  created_at          :datetime         not null
#  account_id          :bigint           not null
#  conversation_id     :bigint           not null
#  from_stage_id       :bigint
#  operational_flow_id :bigint           not null
#  to_stage_id         :bigint
#  user_id             :bigint
#
# Indexes
#
#  idx_stage_events_conversation_created           (conversation_id,created_at)
#  idx_stage_events_flow_created                   (operational_flow_id,created_at)
#  index_conversation_stage_events_on_account_id   (account_id)
#  index_conversation_stage_events_on_to_stage_id  (to_stage_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (conversation_id => conversations.id) ON DELETE => cascade
#  fk_rails_...  (from_stage_id => resolution_states.id) ON DELETE => nullify
#  fk_rails_...  (operational_flow_id => operational_flows.id) ON DELETE => cascade
#  fk_rails_...  (to_stage_id => resolution_states.id) ON DELETE => nullify
#
class ConversationStageEvent < ApplicationRecord
  SOURCES = %w[manual result automation auto backfill].freeze

  belongs_to :account
  belongs_to :conversation
  belongs_to :operational_flow
  belongs_to :from_stage, class_name: 'ResolutionState', optional: true
  belongs_to :to_stage, class_name: 'ResolutionState', optional: true
  belongs_to :user, optional: true

  validates :source, inclusion: { in: SOURCES }

  # The move's side effects run only once it is committed (the caller may wrap the move in a
  # transaction). A backfill puts an existing backlog on the board silently: no activity line and
  # no burst of "on enter" automations.
  after_create_commit :announce_move, unless: :backfill?

  private

  def backfill?
    source == 'backfill'
  end

  def announce_move
    create_activity
    Pipelines::StageEnteredJob.perform_later(conversation_id, to_stage_id) if to_stage_id.present?
  end

  def create_activity
    stage_name = to_stage&.display_label
    return if stage_name.blank?

    content = I18n.with_locale(account.locale) do
      if user
        I18n.t('conversations.activity.pipeline.moved', user_name: user.name, stage_name: stage_name)
      else
        I18n.t('conversations.activity.pipeline.moved_by_system', stage_name: stage_name)
      end
    end
    ::Conversations::ActivityMessageJob.perform_later(
      conversation, { account_id: account_id, inbox_id: conversation.inbox_id, message_type: :activity, content: content }
    )
  end
end
