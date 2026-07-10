require 'rails_helper'

# Fallback PDF->visão quando a extração de texto vem pobre (PDF escaneado/foto), + débito de crédito
# das chamadas de visão. Ver Ai::Workers::MediaProcessor.
RSpec.describe Ai::Workers::MediaProcessor do
  describe '.poor_extraction? (detecção de extração pobre)' do
    # Caso REAL da CNH: raw=1012, nonws=387 (só rótulos do template), ws_ratio=62%, 1 página.
    it 'dispara o fallback para o caso real da CNH (387 não-brancos, 62% whitespace, 1 pág)' do
      cnh = ('a' * 387) + ("\n" * 625) # raw=1012, nonws=387, ws=0.617
      expect(described_class.poor_extraction?(cnh, 1)).to be(true)
    end

    it 'NÃO dispara para PDF de texto denso (muito conteúdo, pouco whitespace)' do
      dense = ('lorem ipsum ' * 200).strip # ~2000 não-brancos, ws ~17%, 1 pág
      expect(described_class.poor_extraction?(dense, 1)).to be(false)
    end

    it 'dispara para texto vazio' do
      expect(described_class.poor_extraction?('', 1)).to be(true)
    end

    it 'dispara pela regra de whitespace mesmo com muitos não-brancos (formulário cheio de rótulos)' do
      # nonws=800 (>= 600, passaria no teste de volume) mas 62% de whitespace -> pobre pela 2ª regra
      form = ('a' * 800) + (' ' * 1300) # raw=2100, nonws=800, ws=0.619
      expect(described_class.poor_extraction?(form, 1)).to be(true)
    end

    it 'dispara quando o conteúdo por página fica abaixo do limiar (multipágina)' do
      # 2 páginas, 1000 não-brancos < 2*600=1200 -> pobre
      text = ('a' * 1000) + ("\n" * 50)
      expect(described_class.poor_extraction?(text, 2)).to be(true)
    end

    it 'NÃO dispara para documento real multipágina com conteúdo suficiente' do
      text = (('conteudo real da pagina ' * 80).strip + "\n") * 2 # ~2 págs densas
      expect(described_class.poor_extraction?(text, 2)).to be(false)
    end
  end
end
