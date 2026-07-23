require 'rails_helper'

# Gap 1 — detector de recusa/ausência de slot (A sentinela + B expressão, com guard (d) do extractor).
# Rodar: docker compose exec rails bundle exec rspec spec/services/ai/slot_absence_spec.rb
RSpec.describe Ai::SlotAbsence do
  describe '.declined?' do
    def declined(value:, text:, type: 'text', options: [])
      described_class.declined?(value: value, text: text, type: type, options: options)
    end

    context '(A) sentinela instruída no valor do modelo' do
      it 'detecta o token ABSENT' do
        expect(declined(value: Ai::StepSlot::ABSENT, text: '')).to be(true)
      end
    end

    context '(B) expressão de recusa' do
      it 'detecta expressão EXATA no valor do modelo ("não informado")' do
        expect(declined(value: 'não informado', text: '')).to be(true)
      end

      it 'detecta expressão no TEXTO do turno (modelo mudo)' do
        expect(declined(value: nil, text: 'não tenho email')).to be(true)
      end

      it 'NÃO dispara por frase genérica não-ancorada ("não tenho tempo" numa etapa de email)' do
        expect(declined(value: nil, text: 'não tenho tempo agora', type: 'email')).to be(false)
      end
    end

    context '(d) guard: valor extraível no texto vence a recusa' do
      it 'captura o e-mail em "não tenho email mas pode usar joao@x.com" (não é recusa)' do
        expect(declined(value: nil, text: 'não tenho email mas pode usar joao@x.com', type: 'email')).to be(false)
      end
    end

    it 'valor válido do modelo não é recusa' do
      expect(declined(value: 'joao@x.com', text: 'meu email', type: 'email')).to be(false)
    end
  end

  describe '.absence_value? (usado pelo gate do supervisor — só o valor)' do
    it 'true para o token e para expressão exata; false para valor real' do
      expect(described_class.absence_value?(Ai::StepSlot::ABSENT)).to be(true)
      expect(described_class.absence_value?('não possui')).to be(true)
      expect(described_class.absence_value?('joao@x.com')).to be(false)
      expect(described_class.absence_value?('')).to be(false)
    end
  end
end
