# == Schema Information
#
# Table name: ai_knowledge_sources
#
#  id               :bigint           not null, primary key
#  kind             :string           default("faq"), not null
#  price            :string
#  raw              :text
#  status           :string           default("active"), not null
#  title            :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  ai_department_id :bigint
#
# Indexes
#
#  index_ai_knowledge_sources_on_ai_department_id  (ai_department_id)
#
class Ai::KnowledgeSource < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id, optional: true
  has_many :chunks, class_name: 'Ai::KnowledgeChunk', foreign_key: :ai_knowledge_source_id, dependent: :destroy

  scope :active, -> { where(status: 'active') }

  # Keep the retrievable chunks in sync: website sources are crawled (which then ingests),
  # the others are ingested directly from title/raw.
  after_commit :sync_knowledge, on: %i[create update]

  private

  def sync_knowledge
    if kind == 'website'
      Ai::SiteCrawlJob.perform_later(id) if previously_new_record? || saved_change_to_title?
    elsif previously_new_record? || saved_change_to_title? || saved_change_to_raw?
      Ai::KnowledgeIngestJob.perform_later(id)
    end
  end
end
