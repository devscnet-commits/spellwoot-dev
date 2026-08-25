require 'rails_helper'

RSpec.describe Ai::Workers::MediaProcessor do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:message) { create(:message, conversation: conversation) }
  let(:attachment) { message.attachments.create!(account: account, file_type: :audio) }

  # Anexa um áudio real (fixture) simulando a entrega do WhatsApp/uazapi. O default reproduz o BUG
  # real: conteúdo opus entregue com filename ".mp3" (o filename mentia sobre o formato).
  def attach_audio(filename: 'CNH-e.mp3', content_type: 'audio/opus')
    attachment.file.attach(
      io: File.open(Rails.public_path.join('audio/widget/ding.mp3')),
      filename: filename, content_type: content_type, identify: false
    )
    attachment
  end

  before do
    # Chave da plataforma (openai_key cai aqui quando a conta não tem chave no Hub).
    InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_API_KEY') { |c| c.value = 'test-api-key' }
  end

  describe '.transcribe' do
    let(:openai_client) { instance_double(OpenAI::Client) }
    let(:audio_api) { double('openai_audio') }

    before do
      allow(OpenAI::Client).to receive(:new).and_return(openai_client)
      allow(openai_client).to receive(:audio).and_return(audio_api)
    end

    it 'transcreve com sucesso via ruby-openai e NÃO usa HTTParty' do
      attach_audio
      allow(audio_api).to receive(:transcribe).and_return({ 'text' => 'olá, quero contratar internet' })
      expect(HTTParty).not_to receive(:post)

      result = described_class.transcribe(attachment, account.id)

      expect(result).to eq('[Transcrição do áudio]: olá, quero contratar internet')
    end

    it 'chama o Whisper com model whisper-1 e language pt' do
      attach_audio
      expect(audio_api).to receive(:transcribe)
        .with(hash_including(parameters: hash_including(model: 'whisper-1', language: 'pt')))
        .and_return({ 'text' => 'ok' })

      described_class.transcribe(attachment, account.id)
    end

    it 'resolve a chave via OpenAI::Client (access_token)' do
      attach_audio
      allow(audio_api).to receive(:transcribe).and_return({ 'text' => 'ok' })

      described_class.transcribe(attachment, account.id)

      expect(OpenAI::Client).to(have_received(:new) { |**kwargs| expect(kwargs[:access_token]).to be_present })
    end

    it 'cai no marcador (retorna nil) quando o Whisper devolve texto vazio (áudio sem fala)' do
      attach_audio
      allow(audio_api).to receive(:transcribe).and_return({ 'text' => '' })

      expect(described_class.transcribe(attachment, account.id)).to be_nil
    end

    it 'REGRESSÃO: cenário real (opus entregue como .mp3) não estoura multipart — usa o client e transcreve' do
      # Antes: HTTParty montava um multipart inválido -> OpenAI respondia "Could not parse multipart
      # form" (HTTP 400) e a transcrição NUNCA passava. Agora vai pelo ruby-openai.
      attach_audio(filename: 'CNH-e.pdf.mp3', content_type: 'audio/opus')
      allow(audio_api).to receive(:transcribe).and_return({ 'text' => 'transcrição real do áudio' })
      expect(HTTParty).not_to receive(:post)

      expect(described_class.transcribe(attachment, account.id))
        .to eq('[Transcrição do áudio]: transcrição real do áudio')
    end

    it 'loga e cai no marcador (nil) quando a API do Whisper falha' do
      attach_audio
      allow(audio_api).to receive(:transcribe).and_raise(Faraday::BadRequestError.new('boom'))

      expect(described_class.transcribe(attachment, account.id)).to be_nil
    end

    it 'pula a transcrição (nil) quando não há arquivo anexado' do
      expect(described_class.transcribe(attachment, account.id)).to be_nil
    end
  end

  describe '.audio_extension' do
    it 'deriva do content_type REAL (opus entregue como .mp3 -> .ogg)' do
      expect(described_class.audio_extension(attach_audio(filename: 'x.mp3', content_type: 'audio/opus'))).to eq('.ogg')
    end

    it 'cai na extensão do filename quando o content_type é desconhecido' do
      expect(described_class.audio_extension(attach_audio(filename: 'nota.wav', content_type: 'application/octet-stream'))).to eq('.wav')
    end

    it 'default .ogg quando não há content_type mapeado nem extensão no filename' do
      expect(described_class.audio_extension(attach_audio(filename: 'semext', content_type: 'application/octet-stream'))).to eq('.ogg')
    end
  end

  describe '.extract (fallback do marcador)' do
    let(:openai_client) { instance_double(OpenAI::Client) }
    let(:audio_api) { double('openai_audio') }

    before do
      allow(OpenAI::Client).to receive(:new).and_return(openai_client)
      allow(openai_client).to receive(:audio).and_return(audio_api)
    end

    it 'usa o marcador genérico quando a transcrição volta vazia' do
      attach_audio
      allow(audio_api).to receive(:transcribe).and_return({ 'text' => '' })

      expect(described_class.extract(attachment, account.id)).to eq('[O cliente enviou um áudio]')
    end
  end

  # skip_vision: Ai::Gateway passa true quando department.behavior['python_orchestrator'] está ligado
  # (a OpenAI já recebe a imagem crua via image_url, o OCR legado fica redundante). Cirúrgico — só a
  # imagem é pulada; áudio/documento/vídeo continuam rodando nos dois caminhos.
  describe '.process com skip_vision' do
    it 'skip_vision: true pula a imagem (nem o marcador genérico é gravado) mas continua transcrevendo áudio' do
      message.attachments.create!(account: account, file_type: :image)
      audio = message.attachments.create!(account: account, file_type: :audio)
      audio.file.attach(
        io: File.open(Rails.public_path.join('audio/widget/ding.mp3')),
        filename: 'audio.mp3', content_type: 'audio/mpeg', identify: false
      )
      allow(described_class).to receive(:transcribe).and_return('[Transcrição do áudio]: oi')

      result = described_class.process(message, nil, skip_vision: true)

      expect(result).to eq('[Transcrição do áudio]: oi')
    end

    it 'skip_vision: false (default) grava o marcador genérico da imagem quando não há worker de OCR configurado' do
      message.attachments.create!(account: account, file_type: :image)

      expect(described_class.process(message, nil)).to eq('[O cliente enviou uma imagem]')
    end
  end
end
