require 'rails_helper'

RSpec.describe Ai::HandoffSummary do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }

  def build_summary(**attrs)
    described_class.new({ account: account, conversation: conversation, reason: 'loop',
                          content: 'resumo' }.merge(attrs))
  end

  describe 'validações' do
    it 'é válido com reason e content' do
      expect(build_summary).to be_valid
    end

    it 'exige reason' do
      expect(build_summary(reason: nil)).not_to be_valid
    end

    it 'exige content' do
      expect(build_summary(content: nil)).not_to be_valid
    end
  end

  describe 'associações' do
    it 'ai_run é opcional (nem sempre há run — geração pode falhar antes)' do
      expect(build_summary(ai_run_id: nil)).to be_valid
    end
  end

  describe '.latest_for' do
    it 'retorna o resumo mais recente da conversa' do
      described_class.create!(account: account, conversation: conversation, reason: 'loop', content: 'antigo',
                              created_at: 2.hours.ago)
      novo = described_class.create!(account: account, conversation: conversation, reason: 'credit_exhausted',
                                     content: 'recente')

      expect(described_class.latest_for(conversation.id)).to eq(novo)
    end

    it 'retorna nil quando a conversa não tem nenhum resumo' do
      expect(described_class.latest_for(conversation.id)).to be_nil
    end

    it 'escopa por conversa (não vaza de outra conversa)' do
      outra = create(:conversation, account: account)
      described_class.create!(account: account, conversation: outra, reason: 'loop', content: 'da outra')

      expect(described_class.latest_for(conversation.id)).to be_nil
    end
  end
end
