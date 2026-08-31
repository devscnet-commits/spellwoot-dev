class Whatsapp::MessageTemplateService
  DEFAULT_API_VERSION = 'v22.0'.freeze
  TEMPLATE_STATUS_PENDING = 'PENDING'.freeze

  def initialize(whatsapp_channel)
    @whatsapp_channel = whatsapp_channel
  end

  def create_template(params)
    validator = Whatsapp::MessageTemplateValidator.new(params)
    return { success: false, error: validator.errors.join(', ') } unless validator.valid?

    response = send_template_creation_request(build_request_body(params))
    process_response(response, params)
  end

  def list_templates
    response = HTTParty.get(
      "#{business_account_path}/message_templates",
      query: { fields: 'id,name,category,status,language,quality_score' },
      headers: api_headers
    )
    process_list_response(response)
  end

  private

  def process_list_response(response)
    if response.success?
      { success: true, templates: (response['data'] || []).map { |template| format_template(template) } }
    else
      Rails.logger.error "[WHATSAPP] Template list fetch failed: #{response.code} - #{response.body}"
      { success: false, error: 'Failed to fetch templates', response_body: response.body }
    end
  end

  def format_template(template)
    {
      id: template['id'],
      name: template['name'],
      category: template['category'],
      status: template['status'],
      language: template['language'],
      quality: template.dig('quality_score', 'score')
    }
  end

  def build_request_body(params)
    {
      name: params[:name],
      language: params[:language],
      category: params[:category],
      components: build_components(params)
    }
  end

  def build_components(params)
    [
      { type: 'BODY', text: params[:body] },
      footer_component(params[:footer]),
      buttons_component(params[:buttons])
    ].compact
  end

  def footer_component(footer)
    return if footer.blank?

    { type: 'FOOTER', text: footer }
  end

  def buttons_component(buttons)
    return if buttons.blank?

    { type: 'BUTTONS', buttons: buttons.map { |button| build_button(button) } }
  end

  def build_button(button)
    case button[:type]
    when 'URL'
      build_url_button(button)
    when 'PHONE_NUMBER'
      { type: 'PHONE_NUMBER', text: button[:text], phone_number: button[:phone_number] }
    when 'COPY_CODE'
      { type: 'COPY_CODE', example: button[:example] }
    else
      { type: 'QUICK_REPLY', text: button[:text] }
    end
  end

  def build_url_button(button)
    url_button = { type: 'URL', text: button[:text], url: button[:url] }
    url_button[:example] = [button[:example]] if button[:example].present?
    url_button
  end

  def send_template_creation_request(request_body)
    HTTParty.post(
      "#{business_account_path}/message_templates",
      headers: api_headers,
      body: request_body.to_json
    )
  end

  def process_response(response, params)
    if response.success?
      {
        success: true,
        template_id: response['id'],
        template_name: params[:name],
        status: TEMPLATE_STATUS_PENDING,
        language: params[:language]
      }
    else
      Rails.logger.error "[WHATSAPP] Template creation failed: #{response.code} - #{response.body}"
      { success: false, error: 'Template creation failed', response_body: response.body }
    end
  end

  def business_account_path
    "#{api_base_path}/#{api_version}/#{@whatsapp_channel.provider_config['business_account_id']}"
  end

  def api_version
    GlobalConfigService.load('WHATSAPP_API_VERSION', DEFAULT_API_VERSION)
  end

  def api_headers
    {
      'Authorization' => "Bearer #{@whatsapp_channel.provider_config['api_key']}",
      'Content-Type' => 'application/json'
    }
  end

  def api_base_path
    ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
  end
end
