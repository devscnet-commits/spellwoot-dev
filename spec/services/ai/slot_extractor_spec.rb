require 'rails_helper'

RSpec.describe Ai::SlotExtractor do
  describe '.extract — cpf' do
    it 'extrai e formata um CPF válido com pontuação' do
      expect(described_class.extract(attribute_type: 'cpf', text: 'meu cpf é 111.444.777-35, ok?'))
        .to eq('111.444.777-35')
    end

    it 'extrai um CPF válido sem pontuação e o formata' do
      expect(described_class.extract(attribute_type: 'cpf', text: 'segue 11144477735')).to eq('111.444.777-35')
    end

    it 'retorna nil para dígitos que não passam no verificador' do
      expect(described_class.extract(attribute_type: 'cpf', text: 'cpf 123.456.789-00')).to be_nil
    end

    it 'retorna nil para sequência repetida (111.111.111-11)' do
      expect(described_class.extract(attribute_type: 'cpf', text: '111.111.111-11')).to be_nil
    end

    it 'retorna nil quando não há CPF no texto' do
      expect(described_class.extract(attribute_type: 'cpf', text: 'não sei meu cpf agora')).to be_nil
    end
  end

  describe '.extract — email' do
    it 'extrai e normaliza (downcase) um email' do
      expect(described_class.extract(attribute_type: 'email', text: 'É Joao@Empresa.COM.br pode?'))
        .to eq('joao@empresa.com.br')
    end

    it 'retorna nil quando não há email' do
      expect(described_class.extract(attribute_type: 'email', text: 'arroba não tem aqui')).to be_nil
    end
  end

  describe '.extract — phone' do
    it 'extrai telefone com DDD e separadores (11 dígitos)' do
      expect(described_class.extract(attribute_type: 'phone', text: 'me liga (49) 99999-9999')).to eq('49999999999')
    end

    it 'descarta o +55 do país e mantém DDD + número' do
      expect(described_class.extract(attribute_type: 'phone', text: '+55 49 3333-4444')).to eq('4933334444')
    end

    it 'retorna nil quando não há telefone plausível' do
      expect(described_class.extract(attribute_type: 'phone', text: 'sem número')).to be_nil
    end
  end

  describe '.extract — number' do
    it 'extrai o primeiro inteiro' do
      expect(described_class.extract(attribute_type: 'number', text: 'tenho 3 aparelhos')).to eq('3')
    end

    it 'extrai decimal e troca vírgula por ponto' do
      expect(described_class.extract(attribute_type: 'number', text: 'custa R$ 89,90')).to eq('89.90')
    end

    it 'retorna nil quando não há número' do
      expect(described_class.extract(attribute_type: 'number', text: 'nenhum')).to be_nil
    end
  end

  describe '.extract — choice' do
    let(:options) { %w[Residencial Empresarial] }

    it 'casa a opção ignorando caixa' do
      expect(described_class.extract(attribute_type: 'choice', text: 'quero EMPRESARIAL', options: options))
        .to eq('Empresarial')
    end

    it 'casa a opção ignorando acento e retorna a forma CANÔNICA' do
      expect(described_class.extract(attribute_type: 'choice', text: 'é residencial mesmo', options: options))
        .to eq('Residencial')
    end

    it 'prioriza a opção mais longa (evita casar "5" dentro de "5 a 10")' do
      expect(described_class.extract(attribute_type: 'choice', text: 'de 5 a 10 aparelhos',
                                     options: ['5', '5 a 10'])).to eq('5 a 10')
    end

    it 'retorna nil quando o texto não bate com nenhuma opção' do
      expect(described_class.extract(attribute_type: 'choice', text: 'sei lá', options: options)).to be_nil
    end
  end

  describe '.extract — text e desconhecidos (não extrai)' do
    it 'type=text sempre retorna nil (ambíguo, ex.: nome)' do
      expect(described_class.extract(attribute_type: 'text', text: 'meu nome é Jaque')).to be_nil
    end

    it 'tipo desconhecido retorna nil' do
      expect(described_class.extract(attribute_type: 'qualquer', text: '111.444.777-35')).to be_nil
    end

    it 'texto vazio retorna nil' do
      expect(described_class.extract(attribute_type: 'cpf', text: '   ')).to be_nil
    end
  end
end
