# Invisible worker: turns a message's media attachments into text for the context. For now it
# emits a marker per attachment so the supervisor knows media arrived (and can ask or hand off).
# Real transcription (audio) is implemented via Whisper; OCR (image) is a clearly-marked extension
# point — plug a provider call into ocr when chosen.
class Ai::Workers::MediaProcessor
  def self.process(message)
    attachments = message.attachments.to_a
    return nil if attachments.empty?

    account_id = message.account_id
    attachments.map { |attachment| extract(attachment, account_id) }.compact.join("\n").presence
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] #{e.class}: #{e.message}"
    nil
  end

  def self.extract(attachment, account_id)
    case attachment.file_type
    when 'audio' then transcribe(attachment, account_id) || '[O cliente enviou um áudio]'
    when 'image' then ocr(attachment) || '[O cliente enviou uma imagem]'
    when 'file'  then '[O cliente enviou um arquivo]'
    when 'video' then '[O cliente enviou um vídeo]'
    end
  end

  # Audio transcription via OpenAI Whisper. A chave é resolvida como no ModelRouter: chave da CONTA
  # (Hub "APIs & Credentials") primeiro, senão a chave da plataforma — assim uma conta que só
  # configurou a OpenAI no Hub (IA própria) transcreve, e a conta com "IA integrada" (sem chave
  # própria) cai na plataforma normalmente. Qualquer falha retorna nil (caller usa o marcador
  # genérico), mas agora deixando rastro no log para diferenciar sem-arquivo / sem-chave / erro-API.
  def self.transcribe(attachment, account_id = nil)
    unless attachment.file.attached?
      # Sem arquivo local: o download da mídia falhou no recebimento (uazapi cai em external_url só).
      Rails.logger.warn '[Ai::Workers::MediaProcessor] áudio sem arquivo anexado (download da mídia falhou?), transcrição pulada'
      return nil
    end

    api_key = openai_key(account_id)
    if api_key.blank?
      Rails.logger.warn '[Ai::Workers::MediaProcessor] sem chave OpenAI (conta nem plataforma), transcrição pulada'
      return nil
    end

    extension = File.extname(attachment.file.blob.filename.to_s).presence || '.ogg'
    Tempfile.create(['ai-audio', extension]) do |tmp|
      tmp.binmode
      tmp.write(attachment.file.download)
      tmp.rewind
      response = HTTParty.post(
        'https://api.openai.com/v1/audio/transcriptions',
        headers: { 'Authorization' => "Bearer #{api_key}" },
        multipart: true,
        body: { model: 'whisper-1', file: tmp }
      )
      unless response.success?
        # Falha REAL de API (auth, formato, tamanho) — não logamos o áudio, só o status/erro do Whisper.
        Rails.logger.warn "[Ai::Workers::MediaProcessor] Whisper falhou: HTTP #{response.code}#{whisper_error(response)}"
        return nil
      end

      text = response.parsed_response.is_a?(Hash) ? response.parsed_response['text'] : nil
      return text.present? ? "[Transcrição do áudio]: #{text}" : nil
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] transcrição: #{e.class}: #{e.message}"
    nil
  end

  # Extension point: integrate a vision/OCR provider here.
  def self.ocr(_attachment)
    nil
  end

  # Mensagem de erro do Whisper (OpenAI devolve {"error":{"message":...}}) para o log — sem PII/áudio.
  def self.whisper_error(response)
    msg = response.parsed_response.is_a?(Hash) ? response.parsed_response.dig('error', 'message') : nil
    msg.present? ? " - #{msg}" : ''
  rescue StandardError
    ''
  end

  # Resolução da chave OpenAI: conta (Hub) primeiro, senão plataforma. Espelha o Ai::ModelRouter.
  def self.openai_key(account_id = nil)
    account_openai_key(account_id) || platform_openai_key
  end

  # Chave OpenAI da conta pelo Hub "APIs & Credentials" (account→global→ENV via IntegrationSettings).
  def self.account_openai_key(account_id)
    return nil if account_id.blank? || !defined?(IntegrationSettingsService)

    IntegrationSettingsService.get_config(account_id, 'openai')['apiKey'].presence
  rescue StandardError => e
    Rails.logger.warn "[Ai::Workers::MediaProcessor] lookup da chave OpenAI da conta falhou: #{e.class}: #{e.message}"
    nil
  end

  def self.platform_openai_key
    value = (InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value if defined?(InstallationConfig))
    value.presence || ENV.fetch('OPENAI_API_KEY', nil)
  rescue StandardError
    ENV.fetch('OPENAI_API_KEY', nil)
  end
end
