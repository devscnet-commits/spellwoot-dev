# Link between a Shadow and an inbox it observes.
class Ai::ShadowInbox < ApplicationRecord
  belongs_to :shadow, class_name: 'Ai::Shadow', foreign_key: :ai_shadow_id
  belongs_to :inbox, class_name: '::Inbox'
end
