# Join: an integration an agent is allowed to use.
# == Schema Information
#
# Table name: ai_department_integrations
#
#  id                     :bigint           not null, primary key
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  ai_agent_id            :bigint           not null
#  ai_integration_link_id :bigint           not null
#
# Indexes
#
#  idx_ai_agent_integrations_unique  (ai_agent_id,ai_integration_link_id) UNIQUE
#
class Ai::DepartmentIntegration < ApplicationRecord
  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id
  belongs_to :integration_link, class_name: 'Ai::IntegrationLink', foreign_key: :ai_integration_link_id
end
