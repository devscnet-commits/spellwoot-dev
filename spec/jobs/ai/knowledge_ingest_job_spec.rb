require 'rails_helper'

RSpec.describe Ai::KnowledgeIngestJob do
  let(:job) { described_class.new }

  describe '#chunkify' do
    it 'packs paragraphs into chunks within the size limit' do
      text = (['a' * 300] * 5).join("\n\n")
      chunks = job.send(:chunkify, text)
      expect(chunks).not_to be_empty
      expect(chunks).to all(satisfy { |c| c.length <= described_class::CHUNK_SIZE })
    end

    it 'hard-splits a single paragraph larger than the limit' do
      chunks = job.send(:chunkify, 'x' * ((described_class::CHUNK_SIZE * 2) + 10))
      expect(chunks.length).to be >= 2
    end

    it 'returns empty for blank text' do
      expect(job.send(:chunkify, '   ')).to eq([])
    end
  end

  describe '#perform — embedding robusto' do
    let(:account) { create(:account) }
    let(:vector) { Array.new(1536, 0.01) }

    def source(raw: 'Pergunta e resposta.', status: 'active')
      Ai::KnowledgeSource.create!(account: account, kind: 'faq', title: 'FAQ', raw: raw, status: status)
    end

    def stub_embedder(enabled: true, vector: nil, error: nil)
      emb = instance_double(Ai::Embedder, enabled?: enabled)
      if error
        allow(emb).to receive(:embed).and_raise(error)
      else
        allow(emb).to receive(:embed).and_return(vector)
      end
      allow(Ai::Embedder).to receive(:new).and_return(emb)
      emb
    end

    it 'cria chunks COM vetor quando o embedder funciona' do
      stub_embedder(vector: vector)
      src = source

      described_class.new.perform(src.id)

      chunks = src.reload.chunks
      expect(chunks).to be_present
      expect(chunks.where.not(embedding: nil).count).to eq(chunks.count)
    end

    it 'grava chunks SEM vetor quando não há chave (embedder desligado), sem erro' do
      stub_embedder(enabled: false)
      src = source

      expect { described_class.new.perform(src.id) }.not_to raise_error
      expect(src.reload.chunks.where(embedding: nil).count).to eq(src.chunks.count)
      expect(src.chunks).to be_present
    end

    it 'degrada (grava sem vetor) e NÃO propaga quando a chave é inválida (AuthError)' do
      stub_embedder(error: Ai::Embedder::AuthError.new('invalid key'))
      src = source

      expect { described_class.new.perform(src.id) }.not_to raise_error
      expect(src.reload.chunks.where(embedding: nil).count).to eq(src.chunks.count)
    end

    it 'PROPAGA TransientError (para o Sidekiq re-tentar) e NÃO apaga os chunks existentes' do
      src = source
      src.chunks.create!(content: 'antigo', embedding: nil)
      old_ids = src.chunks.pluck(:id)
      stub_embedder(error: Ai::Embedder::TransientError.new('429'))

      expect { described_class.new.perform(src.id) }.to raise_error(Ai::Embedder::TransientError)
      expect(src.reload.chunks.pluck(:id)).to eq(old_ids) # nada apagado/recriado (troca atômica)
    end

    it 'no caminho de exaustão (force_degrade) grava tudo sem vetor, sem chamar o embedder' do
      expect(Ai::Embedder).not_to receive(:new)
      src = source

      described_class.new.send(:ingest, src.id, force_degrade: true)

      expect(src.reload.chunks).to be_present
      expect(src.chunks.where(embedding: nil).count).to eq(src.chunks.count)
    end
  end
end
