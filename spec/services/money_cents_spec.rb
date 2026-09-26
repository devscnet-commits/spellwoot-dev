require 'rails_helper'

RSpec.describe MoneyCents do
  describe '.parse' do
    it 'converte reais digitados no formato brasileiro para centavos' do
      expect(described_class.parse('8')).to eq(800)
      expect(described_class.parse('8,5')).to eq(850)
      expect(described_class.parse('347,90')).to eq(34_790)
      expect(described_class.parse('1.234,56')).to eq(123_456)
      expect(described_class.parse('R$ 5.000,00')).to eq(500_000)
    end

    it 'aceita ponto como separador decimal quando não há vírgula' do
      expect(described_class.parse('8.50')).to eq(850)
    end

    it 'devolve nil para vazio ou texto inválido' do
      expect(described_class.parse('')).to be_nil
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse('abc')).to be_nil
    end
  end

  describe '.format' do
    it 'mostra centavos como reais no formato brasileiro' do
      expect(described_class.format(800)).to eq('8,00')
      expect(described_class.format(34_790)).to eq('347,90')
      expect(described_class.format(123_456)).to eq('1.234,56')
      expect(described_class.format(7)).to eq('0,07')
      expect(described_class.format(nil)).to be_nil
    end
  end
end
