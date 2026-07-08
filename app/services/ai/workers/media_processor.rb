# Invisible worker: turns a message's media attachments into text for the context. Real transcription
# (audio, Whisper) and image analysis (visão via o worker de OCR do perfil) já implementados; se
# faltar config/arquivo/API cai no marcador genérico. `profile` = Ai::OperationProfile do agente,
# necessário para o OCR ler o worker configurado (worker_overrides['ocr']).
class Ai::Workers::MediaProcessor
  # Cap defensivo de tamanho da imagem. WhatsApp comprime (geralmente < 2MB); redimensionar com
  # mini_magick/image_processing fica p/ o futuro se algum provider exigir menor.
  MAX_IMAGE_BYTES = 20 * 1024 * 1024

  VISION_SYSTEM_PROMPT = 'Você analisa imagens enviadas por clientes num atendimento. Descreva de ' \
                         'forma OBJETIVA e concisa, em português, o que a imagem mostra e o que é ' \
                         'relevante para o atendimento (ex.: print de erro com a mensagem exibida, ' \
                         'comprovante de pagamento com valor/data, foto de equipamento, documento). ' \
                         'Não invente dados que não estão visíveis. Responda apenas a descrição.'

  def self.process(message, profile = nil)
    attachments = message.attachments.to_a
    return nil if attachments.empty?

    account_id = message.account_id
    attachments.map { |attachment| extract(attachment, account_id, profile) }.compact.join("\n").presence
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] #{e.class}: #{e.message}"
    nil
  end

  def self.extract(attachment, account_id, profile = nil)
    case attachment.file_type
    when 'audio' then transcribe(attachment, account_id) || '[O cliente enviou um áudio]'
    when 'image' then ocr(attachment, account_id, profile) || '[O cliente enviou uma imagem]'
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

  # Análise de imagem (visão) usando o provider/modelo do WORKER de OCR do perfil (dinâmico, NÃO
  # hardcoded). Lê a imagem direto do ActiveStorage e passa ao ModelRouter (mesma resolução de chave
  # multi-provider do modelo principal). Qualquer falha retorna nil (caller usa o marcador genérico),
  # com log distinto para diferenciar sem-arquivo / sem-worker / erro-de-API — sem logar a imagem.
  def self.ocr(attachment, account_id, profile)
    unless attachment.file.attached?
      Rails.logger.warn '[Ai::Workers::MediaProcessor] imagem sem arquivo anexado (download da mídia falhou?), OCR pulado'
      return nil
    end

    provider, model = ocr_worker(profile)
    if model.blank?
      # OCR/visão é opt-in (mais caro): sem worker configurado no perfil, não roda.
      Rails.logger.warn '[Ai::Workers::MediaProcessor] sem worker de OCR configurado no perfil, OCR pulado'
      return nil
    end

    if attachment.file.blob.byte_size > MAX_IMAGE_BYTES
      Rails.logger.warn "[Ai::Workers::MediaProcessor] imagem grande demais (#{attachment.file.blob.byte_size} bytes), OCR pulado"
      return nil
    end

    raw = Ai::ModelRouter.call_model(
      provider: provider, model: model,
      system_prompt: VISION_SYSTEM_PROMPT,
      user_message: 'Descreva o conteúdo desta imagem.',
      account_id: account_id, image: attachment.file
    )
    if raw[:status] == 'error'
      Rails.logger.warn "[Ai::Workers::MediaProcessor] visão falhou: #{raw[:error]}"
      return nil
    end

    text = raw[:text].to_s.strip
    text.present? ? "[Imagem]: #{text}" : nil
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] OCR: #{e.class}: #{e.message}"
    nil
  end

  # Worker de OCR do perfil. worker_overrides é aninhado: { 'ocr' => { 'provider'=>, 'model'=> } }.
  # Sem fallback pro supervisor (diferente do Summary) — visão é opt-in. provider default 'openai'
  # quando só o modelo está setado. Retorna [provider, model] (model nil => não configurado).
  def self.ocr_worker(profile)
    cfg = profile&.worker_overrides&.dig('ocr') || {}
    [cfg['provider'].presence || 'openai', cfg['model'].presence]
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
