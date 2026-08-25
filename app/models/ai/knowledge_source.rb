# == Schema Information
#
# Table name: ai_knowledge_sources
#
#  id               :bigint           not null, primary key
#  crawl_error      :text
#  crawl_status     :string
#  kind             :string           default("faq"), not null
#  price            :string
#  raw              :text
#  status           :string           default("active"), not null
#  title            :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  ai_agent_id      :bigint
#
# Indexes
#
#  index_ai_knowledge_sources_on_ai_agent_id  (ai_agent_id)
#
class Ai::KnowledgeSource < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id, optional: true
  has_many :chunks, class_name: 'Ai::KnowledgeChunk', foreign_key: :ai_knowledge_source_id, dependent: :destroy

  scope :active, -> { where(status: 'active') }

  # Optional agent scope must belong to the SAME account (blocks attaching a source to another
  # tenant's agent). nil = shared/account-wide source.
  validate :agent_within_account

  # Keep the retrievable chunks in sync: website sources are crawled (which then ingests),
  # the others are ingested directly from title/raw.
  after_commit :sync_knowledge, on: %i[create update]

  private

  def agent_within_account
    return if ai_agent_id.blank?

    errors.add(:ai_agent_id, 'inválido') unless agent && agent.account_id == account_id
  end

  def sync_knowledge
    if kind == 'website'
      return unless previously_new_record? || saved_change_to_title?

      # 'pending' na hora de enfileirar, não só quando o job termina — sem isto, editar a URL de uma
      # fonte que já tinha falhado (ou já estava indexada) deixava o badge antigo na tela até o job
      # rodar, parecendo que nada aconteceu.
      update_column(:crawl_status, 'pending') # rubocop:disable Rails/SkipsModelValidations
      Ai::SiteCrawlJob.perform_later(id)
    elsif previously_new_record? || saved_change_to_title? || saved_change_to_raw?
      Ai::KnowledgeIngestJob.perform_later(id)
    end
  end
end
