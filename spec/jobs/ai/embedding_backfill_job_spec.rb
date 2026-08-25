require 'rails_helper'

RSpec.describe Ai::EmbeddingBackfillJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }

  def source(status: 'active', updated: 20.minutes.ago, embedding: nil)
    s = Ai::KnowledgeSource.create!(account: account, kind: 'faq', title: 'X', raw: 'y', status: status)
    s.chunks.create!(content: 'c', embedding: embedding)
    # controla o filtro de staleness sem disparar callbacks
    s.update_column(:updated_at, updated) # rubocop:disable Rails/SkipsModelValidations
    s
  end

  def stub_embedder(enabled:)
    allow(Ai::Embedder).to receive(:new).and_return(instance_double(Ai::Embedder, enabled?: enabled))
  end

  before { stub_embedder(enabled: true) } # senão o job é no-op; e não batemos na API real

  it 'reenfileira o ingest para source ativa com chunk sem vetor e "stale"' do
    src = source

    expect { described_class.new.perform }
      .to have_enqueued_job(Ai::KnowledgeIngestJob).with(src.id)
  end

  it 'IGNORA source tocada recentemente (updated_at dentro da janela)' do
    source(updated: 2.minutes.ago)

    expect { described_class.new.perform }.not_to have_enqueued_job(Ai::KnowledgeIngestJob)
  end

  it 'IGNORA source inativa' do
    source(status: 'inactive')

    expect { described_class.new.perform }.not_to have_enqueued_job(Ai::KnowledgeIngestJob)
  end

  it 'IGNORA source cujos chunks já têm vetor' do
    source(embedding: Array.new(1536, 0.1))

    expect { described_class.new.perform }.not_to have_enqueued_job(Ai::KnowledgeIngestJob)
  end

  it 'é no-op quando o embedder está desligado (sem chave)' do
    stub_embedder(enabled: false)
    source

    expect { described_class.new.perform }.not_to have_enqueued_job(Ai::KnowledgeIngestJob)
  end

  it 'respeita o BATCH (não enfileira além do limite por execução)' do
    stub_const("#{described_class}::BATCH", 2)
    3.times { source }

    expect { described_class.new.perform }
      .to have_enqueued_job(Ai::KnowledgeIngestJob).exactly(2).times
  end
end
