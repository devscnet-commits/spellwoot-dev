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

  describe '.document (roteamento PDF texto vs. visão)' do
    let(:account) { create(:account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:message) { create(:message, conversation: conversation) }
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini',
                                   worker_overrides: { 'ocr' => { 'provider' => 'openai', 'model' => 'gpt-4.1-mini' } })
    end
    let(:attachment) do
      att = message.attachments.create!(account: account, file_type: :file)
      att.file.attach(io: StringIO.new('%PDF-1.4 conteudo binario'), filename: 'CNH-e.pdf', content_type: 'application/pdf')
      att
    end

    before do
      # PDF::Reader e a rasterização são stubados (o container de teste não tem ghostscript; a
      # conversão real só roda após rebuild da imagem). Testamos a DECISÃO e o ROTEAMENTO.
      allow(PDF::Reader).to receive(:new).and_return(reader)
      allow(described_class).to receive(:pdf_page_to_png)
        .and_return(instance_double(Tempfile, path: '/tmp/fake-page.png', close!: nil))
    end

    context 'quando a extração é pobre (PDF escaneado)' do
      let(:reader) { double('reader', page_count: 1, pages: [double(text: ('a' * 300) + ("\n" * 800))]) }

      it 'rasteriza e processa via worker de visão; o resultado da visão substitui o texto pobre' do
        allow(Ai::ModelRouter).to receive(:call_model)
          .and_return({ text: 'CNH de João da Silva, categoria B', status: 'recorded', tokens_in: 5, tokens_out: 10 })

        result = described_class.document(attachment, account.id, profile)

        expect(result).to eq('[Documento (PDF escaneado)]: CNH de João da Silva, categoria B')
        expect(Ai::ModelRouter).to have_received(:call_model).with(hash_including(image: '/tmp/fake-page.png'))
      end
    end

    context 'quando a extração é densa (PDF de texto)' do
      let(:reader) { double('reader', page_count: 1, pages: [double(text: 'conteudo real da pagina ' * 100)]) }

      it 'retorna o texto extraído e NÃO chama a visão' do
        expect(Ai::ModelRouter).not_to receive(:call_model)

        result = described_class.document(attachment, account.id, profile)

        expect(result).to start_with('[Documento (PDF)]:')
      end
    end
  end
end
