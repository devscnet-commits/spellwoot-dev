require 'rails_helper'

# Achado ao vivo (18/08): a tela de Perfis de Operação deixa digitar QUALQUER nome de modelo em texto
# livre — nada impedia configurar um modelo de raciocínio (o1/o3/gpt-5) com uma temperature customizada,
# o que rejeita HTTP 400 na primeira conversa real (esses modelos só aceitam temperature == 1, ou nem
# aceitam o parâmetro). #resolve agora devolve nil pra esses — quem chama já sabe omitir o parâmetro.
RSpec.describe Ai::TemperatureMapper do
  describe '.reasoning_model?' do
    it 'reconhece a família o-series (o1, o3, o3-mini, o4-mini...)' do
      expect(described_class.reasoning_model?('o1')).to be(true)
      expect(described_class.reasoning_model?('o3')).to be(true)
      expect(described_class.reasoning_model?('o3-mini')).to be(true)
      expect(described_class.reasoning_model?('o4-mini')).to be(true)
      expect(described_class.reasoning_model?('O3-MINI')).to be(true) # case-insensitive
    end

    it 'reconhece a família gpt-5 (gpt-5, gpt-5-mini, gpt-5-thinking...)' do
      expect(described_class.reasoning_model?('gpt-5')).to be(true)
      expect(described_class.reasoning_model?('gpt-5-mini')).to be(true)
      expect(described_class.reasoning_model?('gpt-5-thinking')).to be(true)
    end

    it 'NÃO confunde modelos normais que começam com "o" ou contêm "gpt-5" no meio do nome' do
      expect(described_class.reasoning_model?('gpt-4.1-mini')).to be(false)
      expect(described_class.reasoning_model?('opus')).to be(false) # começa com 'o' mas não é o+dígito
      expect(described_class.reasoning_model?(nil)).to be(false)
      expect(described_class.reasoning_model?('')).to be(false)
    end
  end

  describe '.resolve' do
    it 'devolve nil pra modelo de raciocínio, ignorando a posição do slider' do
      expect(described_class.resolve('openai', 70, model: 'o3-mini')).to be_nil
      expect(described_class.resolve('openai', 0, model: 'gpt-5')).to be_nil
    end

    it 'resolve normal (interpolação por posição) quando o modelo não é de raciocínio' do
      expect(described_class.resolve('openai', 50, model: 'gpt-4.1-mini')).to eq(0.7)
    end

    it 'sem model: (nil), comportamento igual a antes — resolve normal' do
      expect(described_class.resolve('openai', 50)).to eq(0.7)
    end
  end
end
