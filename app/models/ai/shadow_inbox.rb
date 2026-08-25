# Link between a Shadow and an inbox it observes.
# == Schema Information
#
# Table name: ai_shadow_inboxes
#
#  id           :bigint           not null, primary key
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  ai_shadow_id :bigint           not null
#  inbox_id     :bigint           not null
#
# Indexes
#
#  index_ai_shadow_inboxes_on_ai_shadow_id_and_inbox_id  (ai_shadow_id,inbox_id) UNIQUE
#  index_ai_shadow_inboxes_on_inbox_id                   (inbox_id)
#
class Ai::ShadowInbox < ApplicationRecord
  belongs_to :shadow, class_name: 'Ai::Shadow', foreign_key: :ai_shadow_id
  belongs_to :inbox, class_name: '::Inbox'
end
