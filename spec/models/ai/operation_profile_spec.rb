require 'rails_helper'

RSpec.describe Ai::OperationProfile do
  let(:account) { create(:account) }

  def build_profile(**attrs)
    described_class.new({ account: account, name: 'perfil', supervisor_provider: 'openai',
                          supervisor_model: 'gpt-4.1-mini', temperature_position: 20 }.merge(attrs))
  end

  # Restrição de SEGURANÇA: Groq só com modelos aprovados (um llama recomendou concorrentes no smoke).
  describe 'validação de modelo Groq aprovado (defesa em profundidade)' do
    it 'aceita groq com o modelo APROVADO (openai/gpt-oss-120b)' do
      expect(build_profile(supervisor_provider: 'groq', supervisor_model: 'openai/gpt-oss-120b')).to be_valid
    end

    it 'REJEITA groq com modelo não aprovado (ex.: llama-3.1-8b-instant)' do
      profile = build_profile(supervisor_provider: 'groq', supervisor_model: 'llama-3.1-8b-instant')

      expect(profile).not_to be_valid
      expect(profile.errors[:supervisor_model].join).to match(/não é um modelo Groq aprovado/)
    end

    it 'REJEITA groq com qualquer outro modelo arbitrário (via API direta)' do
      expect(build_profile(supervisor_provider: 'groq', supervisor_model: 'gpt-4.1-mini')).not_to be_valid
    end

    it 'NÃO afeta outros providers — openai aceita qualquer modelo (texto livre)' do
      expect(build_profile(supervisor_provider: 'openai', supervisor_model: 'qualquer-modelo-x')).to be_valid
    end

    it 'NÃO afeta outros providers — anthropic aceita qualquer modelo' do
      expect(build_profile(supervisor_provider: 'anthropic', supervisor_model: 'claude-qualquer')).to be_valid
    end

    it 'a lista de aprovados contém o gpt-oss-120b' do
      expect(described_class::GROQ_APPROVED_MODELS).to include('openai/gpt-oss-120b')
    end
  end
end
