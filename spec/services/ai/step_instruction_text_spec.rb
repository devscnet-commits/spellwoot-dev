require 'rails_helper'

RSpec.describe Ai::StepInstructionText do
  describe '.render' do
    it 'nil para step que não é Hash' do
      expect(described_class.render(nil)).to be_nil
      expect(described_class.render('etapa antiga em string')).to be_nil
    end

    it 'etapa NOVA (objective/rules/suggested_script): monta o bloco estruturado' do
      step = {
        'objective' => 'Obter a cidade e o tipo de cliente',
        'rules' => ['Não repita a pergunta se o cliente já respondeu', 'Aceite sinônimos'],
        'suggested_script' => 'Oi! Pra eu te ajudar, me diz sua cidade?'
      }

      text = described_class.render(step)

      expect(text).to eq(<<~TEXT.strip)
        Objetivo: Obter a cidade e o tipo de cliente
        Regras:
        - Não repita a pergunta se o cliente já respondeu
        - Aceite sinônimos
        Fala sugerida: "Oi! Pra eu te ajudar, me diz sua cidade?"
      TEXT
    end

    it 'etapa NOVA com só objective (sem rules/suggested_script): omite os blocos vazios' do
      step = { 'objective' => 'Só o objetivo' }

      expect(described_class.render(step)).to eq('Objetivo: Só o objetivo')
    end

    it 'aceita chaves symbol (mesma tolerância do resto do codebase)' do
      step = { objective: 'Via symbol', rules: ['Regra via symbol'], suggested_script: 'Fala via symbol' }

      text = described_class.render(step)

      expect(text).to include('Objetivo: Via symbol')
      expect(text).to include('- Regra via symbol')
      expect(text).to include('Fala sugerida: "Fala via symbol"')
    end

    it 'rules vazias/em branco são descartadas (não vira "- " solto)' do
      step = { 'objective' => 'x', 'rules' => ['', '   ', 'Regra real'] }

      text = described_class.render(step)

      expect(text).to include("Regras:\n- Regra real")
      expect(text.scan('- ').size).to eq(1)
    end

    # ETAPA ANTIGA: nenhum dos 3 campos novos preenchido -> cai no texto livre de instructions,
    # SEM reformatar (não inventa Objetivo/Regras que a etapa antiga nunca teve).
    it 'etapa ANTIGA (só instructions): fallback com o texto ORIGINAL, sem reformatar' do
      step = { 'name' => 'Cadastro', 'instructions' => 'Peça e grave o CPF do cliente.' }

      expect(described_class.render(step)).to eq('Peça e grave o CPF do cliente.')
    end

    it 'etapa sem NENHUM campo de instrução: nil' do
      expect(described_class.render({ 'name' => 'Boas-vindas' })).to be_nil
    end

    it 'objective/rules/suggested_script presentes (mesmo 1 só) tomam PRECEDÊNCIA sobre instructions legado' do
      step = { 'objective' => 'Novo formato', 'instructions' => 'Texto antigo que devia ser ignorado' }

      expect(described_class.render(step)).to eq('Objetivo: Novo formato')
    end
  end
end
