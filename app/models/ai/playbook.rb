# Structured playbook. The user fills structure (objetivo/steps/transfer_when/close_when/messages)
# and the system compiles it into the final prompt — the user never writes raw prompt.
class Ai::Playbook < ApplicationRecord
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id
end
