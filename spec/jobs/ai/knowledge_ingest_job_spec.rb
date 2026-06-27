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
end
