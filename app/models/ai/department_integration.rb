# Join: an integration a department is allowed to use.
# == Schema Information
#
# Table name: ai_department_integrations
#
#  id                     :bigint           not null, primary key
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  ai_department_id       :bigint           not null
#  ai_integration_link_id :bigint           not null
#
# Indexes
#
#  idx_ai_dept_integrations_unique  (ai_department_id,ai_integration_link_id) UNIQUE
#
class Ai::DepartmentIntegration < ApplicationRecord
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id
  belongs_to :integration_link, class_name: 'Ai::IntegrationLink', foreign_key: :ai_integration_link_id
end
