# Uploads a header media file (image/video/document) to Meta's Resumable Upload API so it can be
# referenced as a message template's HEADER component. Two-step flow per Meta's docs:
# 1. POST /<APP_ID>/uploads to start a session and get an upload session ID.
# 2. POST /upload:<SESSION_ID> with the file bytes to get back the file handle (`h`) that
#    goes into the template's header example.header_handle.
class Whatsapp::MediaUploadService
  ALLOWED_FILE_TYPES = %w[application/pdf image/jpeg image/jpg image/png video/mp4].freeze
  DEFAULT_API_VERSION = 'v22.0'.freeze

  def initialize(whatsapp_channel)
    @whatsapp_channel = whatsapp_channel
  end

  def upload(file)
    return { success: false, error: "Unsupported file type: #{file.content_type}" } unless ALLOWED_FILE_TYPES.include?(file.content_type)

    session_id = start_upload_session(file)
    return { success: false, error: 'Could not start upload session with Meta' } if session_id.blank?

    handle = upload_file_bytes(session_id, file)
    return { success: false, error: 'Could not upload file to Meta' } if handle.blank?

    { success: true, handle: handle }
  end

  private

  def start_upload_session(file)
    response = HTTParty.post(
      "#{api_base_path}/#{api_version}/#{app_id}/uploads",
      query: {
        file_name: file.original_filename,
        file_length: file.size,
        file_type: file.content_type,
        access_token: access_token
      }
    )

    unless response.success?
      Rails.logger.error "[WHATSAPP] Media upload session start failed: #{response.code} - #{response.body}"
      return nil
    end

    response['id']
  end

  def upload_file_bytes(session_id, file)
    response = HTTParty.post(
      "#{api_base_path}/#{api_version}/#{session_id}",
      headers: { 'Authorization' => "OAuth #{access_token}", 'file_offset' => '0' },
      body: file.read
    )

    unless response.success?
      Rails.logger.error "[WHATSAPP] Media upload failed: #{response.code} - #{response.body}"
      return nil
    end

    response['h']
  end

  def app_id
    GlobalConfigService.load('WHATSAPP_APP_ID', '')
  end

  def access_token
    @whatsapp_channel.provider_config['api_key']
  end

  def api_version
    GlobalConfigService.load('WHATSAPP_API_VERSION', DEFAULT_API_VERSION)
  end

  def api_base_path
    ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
  end
end
