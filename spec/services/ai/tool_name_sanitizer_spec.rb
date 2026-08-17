require 'rails_helper'

# Achado ao vivo: a OpenAI rejeitou o payload com 400 "Invalid 'tools[20].name': string does not
# match pattern" — as chaves do Ai::CapabilityRegistry (conversation.resolve, conversation.add_label,
# contact.update_attributes...) têm ponto, fora do padrão ^[a-zA-Z0-9_-]+$ que a OpenAI exige.
RSpec.describe Ai::ToolNameSanitizer do
  describe '.sanitize' do
    it 'troca ponto por underline' do
      expect(described_class.sanitize('conversation.resolve')).to eq('conversation_resolve')
    end

    it 'troca QUALQUER caractere fora de [a-zA-Z0-9_-] — não só ponto (Ai::Tool#name não tem validação de formato)' do
      expect(described_class.sanitize('Verificar CEP (ViaCEP)')).to eq('Verificar_CEP__ViaCEP_')
    end

    it 'nome já seguro passa intacto (idempotente)' do
      expect(described_class.sanitize('registrar_endereco')).to eq('registrar_endereco')
      expect(described_class.sanitize(described_class.sanitize('conversation.resolve'))).to eq('conversation_resolve')
    end
  end

  describe '.resolve' do
    it 'acha o candidato ORIGINAL cujo sanitize bate com o nome recebido' do
      candidates = ['conversation.resolve', 'conversation.transfer', 'avancar_etapa']

      expect(described_class.resolve('conversation_resolve', candidates)).to eq('conversation.resolve')
    end

    it 'sem candidato correspondente, devolve o nome sanitizado como veio (fallback — mesmo comportamento de hoje pra tool desconhecida)' do
      expect(described_class.resolve('nada_bate_aqui', ['conversation.resolve'])).to eq('nada_bate_aqui')
    end

    it 'candidato já seguro (sem caractere pra trocar) resolve pra si mesmo' do
      expect(described_class.resolve('registrar_endereco', ['registrar_endereco', 'conversation.resolve'])).to eq('registrar_endereco')
    end
  end
end
