class Ai::DepartmentInbox < ApplicationRecord
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id
  belongs_to :inbox, class_name: '::Inbox'
end
