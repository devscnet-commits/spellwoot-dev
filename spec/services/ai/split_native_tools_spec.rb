require 'rails_helper'

# Tools NATIVAS de leitura do split (Fix 3b): só leitura, reusam o KnowledgeRetriever, chamam o callback
# de auditoria e nunca crasham.
RSpec.describe 'Ai::Tools de leitura (split)' do
  describe Ai::Tools::ListaCatalogo do
    it 'retorna o catálogo completo e chama on_read com os chunks' do
      allow(Ai::KnowledgeRetriever).to receive(:retrieve)
        .with(hash_including(kinds: ['produto'])).and_return(['Plano Fibra 300MB', 'Plano Fibra 600MB'])
      seen = []
      tool = described_class.new(account_id: 1, department_id: 2, on_read: ->(name, _args, chunks) { seen << [name, chunks.size] })

      out = tool.execute

      expect(out).to include('Plano Fibra 300MB', 'Plano Fibra 600MB')
      expect(seen).to eq([['lista_catalogo', 2]])
    end

    it 'catálogo vazio -> aviso curto (sem crash)' do
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
      expect(described_class.new(account_id: 1, department_id: 2).execute).to match(/Nenhum produto/)
    end

    it 'nome estável exposto ao modelo' do
      expect(described_class.new(account_id: 1, department_id: 2).name).to eq('lista_catalogo')
    end
  end

  describe Ai::Tools::BuscaConhecimento do
    it 'busca com kinds:[kind] e devolve os trechos' do
      allow(Ai::KnowledgeRetriever).to receive(:retrieve)
        .with(hash_including(query: 'prazo', kinds: ['faq'])).and_return(['Instala em 5 dias úteis.'])
      out = described_class.new(account_id: 1, department_id: 2).execute(query: 'prazo', kind: 'faq')
      expect(out).to include('Instala em 5 dias úteis.')
    end

    it 'kind inválido -> busca sem filtro (não trava)' do
      expect(Ai::KnowledgeRetriever).to receive(:retrieve).with(hash_including(kinds: nil)).and_return([])
      described_class.new(account_id: 1, department_id: 2).execute(query: 'x', kind: 'inexistente')
    end
  end
end
