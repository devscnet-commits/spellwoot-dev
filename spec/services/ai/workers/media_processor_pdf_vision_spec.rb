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

    # Achado ao vivo: uma CNH em PDF foi lida por ESTA chamada de visão (vision_call, prompt genérico
    # sem contexto da etapa) e alucinou o ano (1997 virou 1991). skip_vision: true (motor Python) corta
    # essa chamada de vez — quem lê é o turno principal, via #pending_vision_images.
    context 'com skip_vision: true (motor Python) e extração pobre (PDF escaneado)' do
      let(:reader) { double('reader', page_count: 1, pages: [double(text: ('a' * 300) + ("\n" * 800))]) }

      it 'NÃO chama a visão própria — devolve nil (o marcador genérico assume em #extract)' do
        expect(Ai::ModelRouter).not_to receive(:call_model)

        expect(described_class.document(attachment, account.id, profile, skip_vision: true)).to be_nil
      end
    end

    context 'com skip_vision: true e extração densa (PDF de texto real)' do
      let(:reader) { double('reader', page_count: 1, pages: [double(text: 'conteudo real da pagina ' * 100)]) }

      it 'continua devolvendo o texto extraído — texto real nunca depende de visão em nenhum motor' do
        result = described_class.document(attachment, account.id, profile, skip_vision: true)

        expect(result).to start_with('[Documento (PDF)]:')
      end
    end
  end

  # Achado ao vivo: uma CNH em PDF foi lida por uma chamada de visão separada (Ai::Workers::
  # MediaProcessor#pdf_via_vision), sem o contexto da etapa, e alucinou o ano (1997 virou 1991).
  # #pending_vision_images substitui essa leitura por páginas rasterizadas que o TURNO PRINCIPAL
  # (Ai::PythonOrchestratorClient, mesmo contexto/regra de "não chutar") lê nativamente.
  describe '.pending_vision_images (motor Python: páginas de PDF escaneado pra visão nativa)' do
    let(:account) { create(:account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:message) { create(:message, conversation: conversation) }

    def attach_pdf(message)
      att = message.attachments.create!(account: account, file_type: :file)
      att.file.attach(io: StringIO.new('%PDF-1.4 conteudo binario'), filename: 'CNH-e.pdf', content_type: 'application/pdf')
      att
    end

    # pdf_page_to_png devolve um Tempfile REAL (não um double) — #pending_vision_images lê os bytes
    # de verdade (File.binread) pra codificar em base64, diferente do describe acima (que só checa
    # SE a visão foi chamada, nunca lê o arquivo).
    def stub_rasterized_page(bytes: 'fake-png-bytes')
      png = Tempfile.new(['fake-page', '.png'])
      png.binmode
      png.write(bytes)
      png.rewind
      allow(described_class).to receive(:pdf_page_to_png).and_return(png)
    end

    it 'PDF escaneado: devolve as páginas rasterizadas como data URI base64' do
      attach_pdf(message)
      allow(PDF::Reader).to receive(:new)
        .and_return(double('reader', page_count: 1, pages: [double(text: ('a' * 300) + ("\n" * 800))]))
      stub_rasterized_page(bytes: 'fake-png-bytes')

      images = described_class.pending_vision_images(message)

      expect(images).to eq(["data:image/png;base64,#{Base64.strict_encode64('fake-png-bytes')}"])
    end

    it 'PDF de texto real (não escaneado): não rasteriza nada — pdf-reader já bastou' do
      attach_pdf(message)
      allow(PDF::Reader).to receive(:new)
        .and_return(double('reader', page_count: 1, pages: [double(text: 'conteudo real da pagina ' * 100)]))
      expect(described_class).not_to receive(:pdf_page_to_png)

      expect(described_class.pending_vision_images(message)).to eq([])
    end

    it 'sem anexo nenhum: lista vazia' do
      expect(described_class.pending_vision_images(message)).to eq([])
    end

    it 'anexo de IMAGEM (não PDF): ignorado — só documentos "file" entram aqui' do
      message.attachments.create!(account: account, file_type: :image)

      expect(described_class.pending_vision_images(message)).to eq([])
    end
  end

  describe 'débito de crédito (Ai::Run vision_ocr)' do
    let(:account) { create(:account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:message) { create(:message, conversation: conversation) }
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini',
                                   worker_overrides: { 'ocr' => { 'provider' => 'openai', 'model' => 'gpt-4.1-mini' } })
    end

    it 'grava um Ai::Run vision_ocr no OCR de imagem (antes não debitava nada)' do
      att = message.attachments.create!(account: account, file_type: :image)
      att.file.attach(io: StringIO.new('fake-image-bytes'), filename: 'foto.jpg', content_type: 'image/jpeg')
      allow(Ai::ModelRouter).to receive(:call_model)
        .and_return({ text: 'foto de um comprovante', status: 'recorded', tokens_in: 3, tokens_out: 7 })

      expect { described_class.ocr(att, account.id, profile, conversation.id) }
        .to change(Ai::Run.where(run_type: 'vision_ocr'), :count).by(1)

      run = Ai::Run.where(run_type: 'vision_ocr').last
      expect(run.account_id).to eq(account.id)
      expect(run.conversation_id).to eq(conversation.id)
      expect(run.tokens_in).to eq(3)
      expect(run.tokens_out).to eq(7)
      expect(run.status).to eq('recorded')
    end

    it 'grava um Ai::Run vision_ocr no fallback de PDF pobre' do
      att = message.attachments.create!(account: account, file_type: :file)
      att.file.attach(io: StringIO.new('%PDF-1.4 binario'), filename: 'CNH.pdf', content_type: 'application/pdf')
      allow(PDF::Reader).to receive(:new)
        .and_return(double('reader', page_count: 1, pages: [double(text: ('a' * 300) + ("\n" * 800))]))
      allow(described_class).to receive(:pdf_page_to_png)
        .and_return(instance_double(Tempfile, path: '/tmp/p.png', close!: nil))
      allow(Ai::ModelRouter).to receive(:call_model)
        .and_return({ text: 'CNH de João', status: 'recorded', tokens_in: 4, tokens_out: 9 })

      expect { described_class.document(att, account.id, profile, conversation.id) }
        .to change(Ai::Run.where(run_type: 'vision_ocr'), :count).by(1)

      expect(Ai::Run.where(run_type: 'vision_ocr').last.conversation_id).to eq(conversation.id)
    end
  end
end
