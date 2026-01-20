# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  private

  def processed_params
    @processed_params ||= params[:entry].try(:first).try(:[], 'changes').try(:first).try(:[], 'value')
  end

  def download_attachment_file(attachment_payload)
    media_id = attachment_payload[:id]
    Rails.logger.info "[WhatsApp Cloud] Downloading attachment media_id=#{media_id} for inbox_id=#{inbox.id}"
    
    url_response = HTTParty.get(
      inbox.channel.media_url(
        media_id,
        inbox.channel.provider_config['phone_number_id']
      ),
      headers: inbox.channel.api_headers
    )
    
    # This url response will be failure if the access token has expired.
    inbox.channel.authorization_error! if url_response.unauthorized?
    
    unless url_response.success?
      Rails.logger.error "[WhatsApp Cloud] Failed to get media URL for media_id=#{media_id}: status=#{url_response.code}, body=#{url_response.body}"
      return nil
    end
    
    download_url = url_response.parsed_response['url']
    unless download_url
      Rails.logger.error "[WhatsApp Cloud] Media URL response missing 'url' field for media_id=#{media_id}: #{url_response.parsed_response.inspect}"
      return nil
    end
    
    Rails.logger.info "[WhatsApp Cloud] Downloading file from URL for media_id=#{media_id}"
    downloaded_file = Down.download(download_url, headers: inbox.channel.api_headers)
    Rails.logger.info "[WhatsApp Cloud] Successfully downloaded attachment media_id=#{media_id}, filename=#{downloaded_file.original_filename}"
    downloaded_file
  rescue StandardError => e
    Rails.logger.error "[WhatsApp Cloud] Error downloading attachment media_id=#{media_id}: #{e.class} - #{e.message}"
    Rails.logger.error "[WhatsApp Cloud] #{e.backtrace.first(5).join("\n")}"
    nil
  end
end
