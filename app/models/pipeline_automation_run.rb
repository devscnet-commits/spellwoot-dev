# Ledger of executed stage automations. The unique (automation, conversation, anchor_at) index is
# what keeps an automation from firing twice for the same stage entry / the same silence.
# == Schema Information
#
# Table name: pipeline_automation_runs
#
#  id                     :bigint           not null, primary key
#  anchor_at              :datetime         not null
#  error                  :string
#  status                 :string           default("running"), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  conversation_id        :bigint           not null
#  pipeline_automation_id :bigint           not null
#
# Indexes
#
#  idx_pipeline_automation_runs_unique                (pipeline_automation_id,conversation_id,anchor_at) UNIQUE
#  index_pipeline_automation_runs_on_conversation_id  (conversation_id)
#
# Foreign Keys
#
#  fk_rails_...  (conversation_id => conversations.id) ON DELETE => cascade
#  fk_rails_...  (pipeline_automation_id => pipeline_automations.id) ON DELETE => cascade
#
class PipelineAutomationRun < ApplicationRecord
  belongs_to :pipeline_automation
  belongs_to :conversation
end
