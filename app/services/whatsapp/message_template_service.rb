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

  # Meta paginates this endpoint (25 items/page by default) — without following `paging.next`,
  # any WABA with more than one page of templates would silently never show the rest (including
  # anything created after the first page filled up).
  def list_templates
    url = "#{business_account_path}/message_templates"
    query = { fields: 'id,name,category,status,language,quality_score,components,rejected_reason', limit: 100 }
    templates = []

    loop do
      response = HTTParty.get(url, query: query, headers: api_headers)
      return process_list_response(response) unless response.success?

      templates.concat(response['data'] || [])
      url = response.dig('paging', 'next')
      break unless url

      query = {}
    end

    { success: true, templates: templates.map { |template| format_template(template) } }
  end

  # The FLOW button needs the numeric ID of a Flow that already exists on the WABA. Asking an admin
  # to copy it out of WhatsApp Manager by hand meant any typo only surfaced ~10s later, as Meta's
  # useless generic "An unknown error has occurred" (OAuthException code 1). Listing them lets the
  # form offer the real ones — and an empty list is itself the answer: this WABA has no Flows yet.
  def list_flows
    response = HTTParty.get(
      "#{business_account_path}/flows",
      query: { fields: 'id,name,status,categories' },
      headers: api_headers
    )

    unless response.success?
      Rails.logger.error "[WHATSAPP] Flow list fetch failed: #{response.code} - #{response.body}"
      return { success: false, error: 'Failed to fetch flows', response_body: response.body }
    end

    { success: true, flows: (response['data'] || []).map { |flow| format_flow(flow) } }
  end

  # Creates the Flow already published: Meta accepts flow_json + publish in one call, and a draft
  # Flow is useless here — the template creation that follows would reject it.
  def create_flow(key:, name:, heading:, submit_label:)
    body = {
      name: name,
      categories: [Whatsapp::FlowCatalog.category_for(key)],
      flow_json: Whatsapp::FlowCatalog.build_flow_json(key, heading: heading, submit_label: submit_label),
      publish: true
    }
    response = HTTParty.post("#{business_account_path}/flows", headers: api_headers, body: body.to_json)
    process_flow_creation_response(response, Whatsapp::FlowCatalog.screen_id_for(key))
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

  # Only published Flows can be attached to a template: a draft one is rejected by Meta at
  # creation time, so surfacing it in the picker would just reproduce the error we are removing.
  def format_flow(flow)
    {
      id: flow['id'],
      name: flow['name'],
      status: flow['status'],
      selectable: flow['status'] == 'PUBLISHED'
    }
  end

  # Meta answers 200 with `validation_errors` when the Flow JSON itself is wrong, so success is not
  # enough on its own — surfacing the first validation message beats a generic failure.
  def process_flow_creation_response(response, screen_id)
    validation_errors = response['validation_errors']
    if response.success? && validation_errors.blank?
      return { success: true, flow: { id: response['id'], name: response['name'], screen_id: screen_id } }
    end

    Rails.logger.error "[WHATSAPP] Flow creation failed: #{response.code} - #{response.body}"
    { success: false, error: flow_creation_error(response, validation_errors) }
  end

  def flow_creation_error(response, validation_errors)
    return validation_errors.first['message'] if validation_errors.present?

    response.dig('error', 'error_user_msg') || response.dig('error', 'message') || 'Failed to create flow'
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

  # sub_category identifies the handful of Meta template types that share the plain
  # header/body/footer shape but behave differently on send — ORDER_STATUS is the first one we
  # support. Omitted when blank so every other template's payload stays byte-identical.
  def build_request_body(params)
    body = {
      name: params[:name],
      language: params[:language],
      category: params[:category],
      components: build_components(params)
    }
    body[:sub_category] = params[:sub_category] if params[:sub_category].present?
    body[:display_format] = 'ORDER_DETAILS' if order_details_template?(params)
    body
  end

  # Meta only treats a template as an order details one when the creation payload carries
  # display_format — the fixed ORDER_DETAILS button alone isn't enough, and without it the template
  # is created as a plain one with a button that does nothing. Inferred from the button instead of
  # being passed down from the builder because the validator already forces that button to be the
  # template's only one (EXCLUSIVE_BUTTON_TYPES), so its presence is unambiguous.
  def order_details_template?(params)
    Array(params[:buttons]).any? { |button| button[:type] == 'ORDER_DETAILS' }
  end

  def build_components(params)
    [
      header_component(params[:header]),
      body_component(params),
      footer_component(params[:footer], params[:category]),
      buttons_component(params[:buttons], params[:category]),
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

  # Meta auto-generates the body for AUTHENTICATION templates (the code delivery text isn't
  # user-editable) and rejects a BODY component that includes a `text` field for that category.
  def body_component(params)
    return { type: 'BODY' } if params[:category] == 'AUTHENTICATION'

    component = { type: 'BODY', text: params[:body] }
    sample_values = params[:body_sample_values]
    component[:example] = { body_text: [sample_values] } if sample_values.present?
    component
  end

  # Meta requires a FOOTER component on AUTHENTICATION templates (it's where the code-expiration
  # notice goes), even though there's no user-editable footer text for that category.
  def footer_component(footer, category)
    return { type: 'FOOTER' } if category == 'AUTHENTICATION'
    return if footer.blank?

    { type: 'FOOTER', text: footer }
  end

  def buttons_component(buttons, category)
    return if buttons.blank?

    { type: 'BUTTONS', buttons: buttons.map { |button| build_button(button, category) } }
  end

  def build_button(button, category)
    case button[:type]
    when 'URL'
      build_url_button(button)
    when 'PHONE_NUMBER'
      { type: 'PHONE_NUMBER', text: button[:text], phone_number: button[:phone_number] }
    when 'COPY_CODE'
      # AUTHENTICATION's "copy the code" button is a different Meta shape (OTP/otp_type) from the
      # generic "copy this promo code" button MARKETING/UTILITY templates use — same UI type,
      # different wire format. No `example` here: Meta renders the OTP itself, it isn't a sample.
      category == 'AUTHENTICATION' ? { type: 'OTP', otp_type: 'COPY_CODE' } : { type: 'COPY_CODE', example: button[:example] }
    when 'CATALOG'
      # The field is required, but Meta rejects any value other than this exact fixed text.
      { type: 'CATALOG', text: 'View catalog' }
    when 'FLOW'
      build_flow_button(button)
    when 'VOICE_CALL'
      # ttl_minutes is optional here — Meta applies its own default (7 days), and leaving it out
      # keeps one less field the admin can get wrong. Add it if the account ever needs to control
      # how long the button stays tappable.
      { type: 'VOICE_CALL', text: button[:text] }
    when 'ORDER_DETAILS'
      # Same as CATALOG — required field, fixed value.
      { type: 'ORDER_DETAILS', text: 'Copy Pix code' }
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
        status: response['status'] || TEMPLATE_STATUS_PENDING,
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
