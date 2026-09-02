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

    session_response = start_upload_session(file)
    return upload_failure('Could not start upload session with Meta', session_response) unless session_response.success?

    upload_response = upload_file_bytes(session_response['id'], file)
    return upload_failure('Could not upload file to Meta', upload_response) unless upload_response.success?

    { success: true, handle: upload_response['h'] }
  end

  private

  def upload_failure(error, response)
    Rails.logger.error "[WHATSAPP] #{error}: #{response.code} - #{response.body}"
    { success: false, error: error, response_body: response.body }
  end

  def start_upload_session(file)
    HTTParty.post(
      "#{api_base_path}/#{api_version}/#{app_id}/uploads",
      query: {
        file_name: file.original_filename,
        file_length: file.size,
        file_type: file.content_type,
        access_token: access_token
      }
    )
  end

  def upload_file_bytes(session_id, file)
    HTTParty.post(
      "#{api_base_path}/#{api_version}/#{session_id}",
      headers: { 'Authorization' => "OAuth #{access_token}", 'file_offset' => '0' },
      body: file.read
    )
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
