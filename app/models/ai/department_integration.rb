# Join: an integration a department is allowed to use.
class Ai::DepartmentIntegration < ApplicationRecord
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id
  belongs_to :integration_link, class_name: 'Ai::IntegrationLink', foreign_key: :ai_integration_link_id
end
