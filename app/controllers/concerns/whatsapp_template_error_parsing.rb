module WhatsappTemplateErrorParsing
  extend ActiveSupport::Concern

  private

  def parse_whatsapp_error(response_body)
    return { user_message: nil, technical_details: nil } if response_body.blank?

    error_data = JSON.parse(response_body)
    whatsapp_error = error_data['error'] || {}

    user_message = whatsapp_error['error_user_msg'] || whatsapp_error['message']
    technical_details = {
      code: whatsapp_error['code'],
      subcode: whatsapp_error['error_subcode'],
      type: whatsapp_error['type'],
      title: whatsapp_error['error_user_title']
    }.compact

    { user_message: user_message, technical_details: technical_details }
  rescue JSON::ParserError
    { user_message: nil, technical_details: response_body }
  end
end
