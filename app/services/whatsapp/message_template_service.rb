class Whatsapp::MessageTemplateService
  DEFAULT_API_VERSION = 'v22.0'.freeze
  TEMPLATE_STATUS_PENDING = 'PENDING'.freeze

  def initialize(whatsapp_channel)
    @whatsapp_channel = whatsapp_channel
  end

  def create_template(params)
    validator = Whatsapp::MessageTemplateValidator.new(params)
    return { success: false, error: validator.errors.join('; ') } unless validator.valid?

    response = send_template_creation_request(build_request_body(params))
    process_response(response, params)
  end

  def list_templates
    response = HTTParty.get(
      "#{business_account_path}/message_templates",
      query: { fields: 'id,name,category,status,language,quality_score,components,rejected_reason' },
      headers: api_headers
    )
    process_list_response(response)
  end

  # Meta's template update endpoint is POST /<TEMPLATE_ID> — a different path shape than creation
  # (which posts to the WABA) — and only accepts category/components/time-to-live. Editing an
  # approved template re-triggers review; only APPROVED/REJECTED/PAUSED templates can be edited
  # (Meta enforces this itself, we don't duplicate that check here).
  def update_template(template_id, params)
    validator = Whatsapp::MessageTemplateValidator.new(params, require_name: false)
    return { success: false, error: validator.errors.join('; ') } unless validator.valid?

    response = send_template_update_request(template_id, build_update_body(params))
    process_update_response(response)
  end

  def delete_template(name)
    response = HTTParty.delete(
      "#{business_account_path}/message_templates?name=#{name}",
      headers: api_headers
    )
    process_delete_response(response)
  end

  private

  def build_update_body(params)
    { category: params[:category], components: build_components(params) }
  end

  def send_template_update_request(template_id, request_body)
    HTTParty.post(
      "#{api_base_path}/#{api_version}/#{template_id}",
      headers: api_headers,
      body: request_body.to_json
    )
  end

  def process_update_response(response)
    if response.success?
      { success: true }
    else
      Rails.logger.error "[WHATSAPP] Template update failed: #{response.code} - #{response.body}"
      { success: false, error: 'Template update failed', response_body: response.body }
    end
  end

  def process_delete_response(response)
    if response.success?
      { success: true }
    else
      Rails.logger.error "[WHATSAPP] Template delete failed: #{response.code} - #{response.body}"
      { success: false, error: 'Template delete failed', response_body: response.body }
    end
  end

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
      quality: template.dig('quality_score', 'score'),
      components: template['components'],
      rejected_reason: normalized_rejected_reason(template['rejected_reason'])
    }
  end

  # Meta returns the literal string "NONE" instead of omitting the field when there's no reason.
  def normalized_rejected_reason(rejected_reason)
    return nil if rejected_reason.blank? || rejected_reason == 'NONE'

    rejected_reason
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
      header_component(params[:header]),
      body_component(params),
      footer_component(params[:footer]),
      buttons_component(params[:buttons]),
      call_permission_request_component(params[:call_permission_request])
    ].compact
  end

  def call_permission_request_component(call_permission_request)
    { type: 'CALL_PERMISSION_REQUEST' } if ActiveModel::Type::Boolean.new.cast(call_permission_request)
  end

  def header_component(header)
    return if header.blank? || header[:type].blank? || header[:type] == 'NONE'

    if header[:type] == 'TEXT'
      { type: 'HEADER', format: 'TEXT', text: header[:text] }
    else
      { type: 'HEADER', format: header[:type], example: { header_handle: [header[:handle]] } }
    end
  end

  def body_component(params)
    component = { type: 'BODY', text: params[:body] }
    sample_values = params[:body_sample_values]
    component[:example] = { body_text: [sample_values] } if sample_values.present?
    component
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
    when 'CATALOG'
      { type: 'CATALOG', text: button[:text] }
    when 'FLOW'
      build_flow_button(button)
    when 'ORDER_DETAILS'
      { type: 'ORDER_DETAILS', text: button[:text] }
    else
      { type: 'QUICK_REPLY', text: button[:text] }
    end
  end

  def build_flow_button(button)
    flow_button = { type: 'FLOW', text: button[:text], flow_id: button[:flow_id], flow_action: 'navigate' }
    flow_button[:navigate_screen] = button[:navigate_screen] if button[:navigate_screen].present?
    flow_button
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
