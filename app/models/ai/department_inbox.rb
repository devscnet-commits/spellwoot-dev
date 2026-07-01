# == Schema Information
#
# Table name: ai_department_inboxes
#
#  id               :bigint           not null, primary key
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  ai_department_id :bigint           not null
#  inbox_id         :bigint           not null
#
# Indexes
#
#  idx_ai_department_inboxes_unique         (ai_department_id,inbox_id) UNIQUE
#  index_ai_department_inboxes_on_inbox_id  (inbox_id)
#
class Ai::DepartmentInbox < ApplicationRecord
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id
  belongs_to :inbox, class_name: '::Inbox'
end
