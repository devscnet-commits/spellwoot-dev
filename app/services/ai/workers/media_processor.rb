# Invisible worker: turns a message's media attachments into text for the context. For now it
# emits a marker per attachment so the supervisor knows media arrived (and can ask or hand off).
# Real transcription (audio) / OCR (image) are clearly-marked extension points — plug a provider
# call into transcribe/ocr when chosen.
class Ai::Workers::MediaProcessor
  def self.process(message)
    attachments = message.attachments.to_a
    return nil if attachments.empty?

    attachments.map { |attachment| extract(attachment) }.compact.join("\n").presence
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] #{e.class}: #{e.message}"
    nil
  end

  def self.extract(attachment)
    case attachment.file_type
    when 'audio' then transcribe(attachment) || '[O cliente enviou um áudio]'
    when 'image' then ocr(attachment) || '[O cliente enviou uma imagem]'
    when 'file'  then '[O cliente enviou um arquivo]'
    when 'video' then '[O cliente enviou um vídeo]'
    end
  end

  # Audio transcription via OpenAI Whisper (reuses the configured OpenAI key). Guarded: any
  # failure returns nil so the caller falls back to the generic marker.
  def self.transcribe(attachment)
    return nil unless attachment.file.attached?

    api_key = openai_key
    return nil if api_key.blank?

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
      return nil unless response.success?

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

  def self.openai_key
    value = (InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value if defined?(InstallationConfig))
    value.presence || ENV.fetch('OPENAI_API_KEY', nil)
  rescue StandardError
    ENV.fetch('OPENAI_API_KEY', nil)
  end
end
