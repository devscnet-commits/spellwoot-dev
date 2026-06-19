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

  # Extension point: integrate a transcription provider (e.g. Whisper) here.
  def self.transcribe(_attachment)
    nil
  end

  # Extension point: integrate a vision/OCR provider here.
  def self.ocr(_attachment)
    nil
  end
end
