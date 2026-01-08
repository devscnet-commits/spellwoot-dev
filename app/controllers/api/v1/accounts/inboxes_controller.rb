class Api::V1::Accounts::InboxesController < Api::V1::Accounts::BaseController
  include Api::V1::InboxesHelper
  before_action :fetch_inbox, except: [:index, :create]
  before_action :fetch_agent_bot, only: [:set_agent_bot]
  before_action :validate_limit, only: [:create]
  # we are already handling the authorization in fetch inbox
  before_action :check_authorization, except: [:show, :health, :uazapi_status]
  before_action :validate_whatsapp_cloud_channel, only: [:health]
  before_action :validate_uazapi_channel, only: [:uazapi_status, :uazapi_connect, :uazapi_disconnect, :uazapi_reconfigure]

  def index
    @inboxes = policy_scope(Current.account.inboxes.order_by_name.includes(:channel, { avatar_attachment: [:blob] }))
  end

  def show; end

  # Deprecated: This API will be removed in 2.7.0
  def assignable_agents
    @assignable_agents = @inbox.assignable_agents
  end

  def campaigns
    @campaigns = @inbox.campaigns
  end

  def avatar
    @inbox.avatar.attachment.destroy! if @inbox.avatar.attached?
    head :ok
  end

  def create
    ActiveRecord::Base.transaction do
      channel = create_channel
      @inbox = Current.account.inboxes.build(
        {
          name: inbox_name(channel),
          channel: channel
        }.merge(
          permitted_params.except(:channel)
        )
      )
      @inbox.save!
    end
  end

  def update
    inbox_params = permitted_params.except(:channel, :csat_config)
    inbox_params[:csat_config] = format_csat_config(permitted_params[:csat_config]) if permitted_params[:csat_config].present?
    @inbox.update!(inbox_params)
    update_inbox_working_hours
    update_channel if channel_update_required?
  end

  def agent_bot
    @agent_bot = @inbox.agent_bot
  end

  def set_agent_bot
    if @agent_bot
      agent_bot_inbox = @inbox.agent_bot_inbox || AgentBotInbox.new(inbox: @inbox)
      agent_bot_inbox.agent_bot = @agent_bot
      agent_bot_inbox.save!
    elsif @inbox.agent_bot_inbox.present?
      @inbox.agent_bot_inbox.destroy!
    end
    head :ok
  end

  def destroy
    ::DeleteObjectJob.perform_later(@inbox, Current.user, request.ip) if @inbox.present?
    render status: :ok, json: { message: I18n.t('messages.inbox_deletetion_response') }
  end

  def sync_templates
    return render status: :unprocessable_entity, json: { error: 'Template sync is only available for WhatsApp channels' } unless whatsapp_channel?

    trigger_template_sync
    render status: :ok, json: { message: 'Template sync initiated successfully' }
  rescue StandardError => e
    render status: :internal_server_error, json: { error: e.message }
  end

  def health
    health_data = Whatsapp::HealthService.new(@inbox.channel).fetch_health_status
    render json: health_data
  rescue StandardError => e
    Rails.logger.error "[INBOX HEALTH] Error fetching health data: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def uazapi_status
    Rails.logger.info "[UAZAPI] Getting status for inbox_id=#{@inbox.id}, channel_id=#{@inbox.channel.id}"
    @inbox.channel.reload if @inbox.channel.is_a?(Channel::Api) # Ensure we have latest webhook_url
    status_data = Whatsapp::UazapiConnectionService.get_status(@inbox.channel)

    if status_data
      Rails.logger.info "[UAZAPI] Status retrieved: status=#{status_data[:status]}, connected=#{status_data[:connected]}, logged_in=#{status_data[:logged_in]}"
      webhook_url = @inbox.channel.webhook_url if @inbox.channel.is_a?(Channel::Api)
      Rails.logger.info "[UAZAPI] Webhook URL: #{webhook_url}" if webhook_url.present?
      response_data = status_data.merge(webhook_url: webhook_url)
      render json: response_data
    else
      Rails.logger.error "[UAZAPI] Failed to fetch status for inbox_id=#{@inbox.id}"
      render json: { error: 'Failed to fetch status' }, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Status error: #{e.message}"
    Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def uazapi_connect
    Rails.logger.info "[UAZAPI] Connecting instance for inbox_id=#{@inbox.id}, channel_id=#{@inbox.channel.id}"
    
    channel = @inbox.channel
    channel.reload if channel.is_a?(Channel::Api) # Ensure we have latest data
    
    unless channel.is_a?(Channel::Api)
      Rails.logger.error "[UAZAPI] Invalid channel type for inbox_id=#{@inbox.id}, channel_type=#{channel.class}"
      return render json: { error: 'Invalid channel type' }, status: :unprocessable_entity
    end
    
    instance_token = channel.additional_attributes&.dig('uazapi_instance_token')
    unless instance_token.present?
      Rails.logger.error "[UAZAPI] Instance token not found for channel_id=#{channel.id}, additional_attributes=#{channel.additional_attributes.inspect}"
      return render json: { error: 'Instance token not found' }, status: :unprocessable_entity
    end

    base_url = Whatsapp::Providers::UazapiService.base_url
    headers = {
      'Content-Type' => 'application/json',
      'token' => instance_token
    }

    # Don't send phone number - just generate QR code
    response = HTTParty.post(
      "#{base_url}/instance/connect",
      headers: headers,
      body: {}.to_json
    )

    if response.success?
      connection_data = response.parsed_response
      Rails.logger.info "[UAZAPI] Connection initiated: status=#{connection_data.dig('instance', 'status')}, qr_code_available=#{connection_data.dig('instance', 'qrcode').present?}"
      render json: {
        qr_code: connection_data.dig('instance', 'qrcode') || connection_data['qrcode'],
        status: connection_data.dig('instance', 'status') || 'connecting',
        pair_code: connection_data.dig('instance', 'paircode')
      }
    else
      Rails.logger.error "[UAZAPI] Failed to connect: #{response.body}"
      render json: { error: 'Failed to connect' }, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Connect error: #{e.message}"
    Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def uazapi_disconnect
    Rails.logger.info "[UAZAPI] Disconnecting instance for inbox_id=#{@inbox.id}, channel_id=#{@inbox.channel.id}"
    
    channel = @inbox.channel
    channel.reload if channel.is_a?(Channel::Api) # Ensure we have latest data
    
    unless channel.is_a?(Channel::Api)
      Rails.logger.error "[UAZAPI] Invalid channel type for inbox_id=#{@inbox.id}, channel_type=#{channel.class}"
      return render json: { error: 'Invalid channel type' }, status: :unprocessable_entity
    end
    
    instance_token = channel.additional_attributes&.dig('uazapi_instance_token')
    unless instance_token.present?
      Rails.logger.error "[UAZAPI] Instance token not found for channel_id=#{channel.id}, additional_attributes=#{channel.additional_attributes.inspect}"
      return render json: { error: 'Instance token not found' }, status: :unprocessable_entity
    end

    base_url = Whatsapp::Providers::UazapiService.base_url
    headers = {
      'Content-Type' => 'application/json',
      'token' => instance_token
    }

    response = HTTParty.post(
      "#{base_url}/instance/disconnect",
      headers: headers
    )

    if response.success?
      Rails.logger.info "[UAZAPI] Instance disconnected successfully"
      render json: { message: 'Disconnected successfully' }
    else
      Rails.logger.error "[UAZAPI] Failed to disconnect: #{response.body}"
      render json: { error: 'Failed to disconnect' }, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Disconnect error: #{e.message}"
    Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def uazapi_reconfigure
    Rails.logger.info "[UAZAPI] Reconfiguring Chatwoot integration for inbox_id=#{@inbox.id}, channel_id=#{@inbox.channel.id}"
    
    channel = @inbox.channel
    return render json: { error: 'Invalid channel type' }, status: :unprocessable_entity unless channel.is_a?(Channel::Api)
    
    instance_token = channel.additional_attributes&.dig('uazapi_instance_token')
    unless instance_token.present?
      Rails.logger.error "[UAZAPI] Instance token not found for channel_id=#{channel.id}"
      return render json: { error: 'Instance token not found' }, status: :unprocessable_entity
    end

    unless Current.user.present?
      Rails.logger.error "[UAZAPI] Current user not available"
      return render json: { error: 'User not authenticated' }, status: :unauthorized
    end

    access_token = Current.user.access_token&.token
    unless access_token.present?
      Rails.logger.warn "[UAZAPI] Access token not available for user_id=#{Current.user.id}"
      return render json: { error: 'Access token not available' }, status: :unprocessable_entity
    end

    frontend_url = ENV.fetch('FRONTEND_URL', nil) || (ENV['HEROKU_APP_NAME'].present? ? "https://#{ENV['HEROKU_APP_NAME']}.herokuapp.com" : nil)
    unless frontend_url.present?
      Rails.logger.warn "[UAZAPI] FRONTEND_URL not configured"
      return render json: { error: 'FRONTEND_URL not configured' }, status: :unprocessable_entity
    end

    chatwoot_config = {
      enabled: true,
      url: frontend_url,
      access_token: access_token,
      account_id: Current.account.id,
      inbox_id: @inbox.id,
      ignore_groups: false,
      sign_messages: true,
      create_new_conversation: true
    }

    result = Whatsapp::Providers::UazapiService.configure_chatwoot_integration(instance_token, chatwoot_config)
    
    unless result.present?
      Rails.logger.error "[UAZAPI] Failed to reconfigure Chatwoot integration - no response from API"
      return render json: { error: 'Failed to reconfigure integration' }, status: :unprocessable_entity
    end

    webhook_url = result&.dig('chatwoot_inbox_webhook_url')
    
    if webhook_url.present?
      Rails.logger.info "[UAZAPI] Chatwoot integration reconfigured successfully, webhook_url=#{webhook_url}"
      channel.update!(webhook_url: webhook_url)
      channel.reload
      render json: { 
        message: 'Integration reconfigured successfully',
        webhook_url: webhook_url
      }
    else
      # API configured successfully but webhook_url not returned - this is ok, we'll keep existing webhook_url
      Rails.logger.info "[UAZAPI] Chatwoot integration reconfigured successfully, but webhook_url not returned in response"
      Rails.logger.info "[UAZAPI] Response: #{result.inspect}"
      render json: { 
        message: 'Integration reconfigured successfully',
        webhook_url: channel.webhook_url # Return existing webhook_url if available
      }
    end
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Reconfigure error: #{e.message}"
    Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.includes(:channel).find(params[:id])
    authorize @inbox, :show?
  end

  def fetch_agent_bot
    @agent_bot = AgentBot.find(params[:agent_bot]) if params[:agent_bot]
  end

  def validate_whatsapp_cloud_channel
    return if @inbox.channel.is_a?(Channel::Whatsapp) && @inbox.channel.provider == 'whatsapp_cloud'

    render json: { error: 'Health data only available for WhatsApp Cloud API channels' }, status: :bad_request
  end

  def validate_uazapi_channel
    Rails.logger.info "[UAZAPI] Validating channel for inbox_id=#{@inbox.id}, channel_id=#{@inbox.channel&.id}, channel_type=#{@inbox.channel&.class}"
    
    unless @inbox.channel.is_a?(Channel::Api)
      Rails.logger.error "[UAZAPI] Channel validation failed: not Channel::Api, channel_type=#{@inbox.channel&.class}"
      render json: { error: 'This endpoint is only available for UazAPI channels' }, status: :bad_request
      return
    end

    instance_token = @inbox.channel.additional_attributes&.dig('uazapi_instance_token')
    unless instance_token.present?
      Rails.logger.error "[UAZAPI] Channel validation failed: instance_token not present for channel_id=#{@inbox.channel.id}"
      render json: { error: 'This endpoint is only available for UazAPI channels' }, status: :bad_request
      return
    end

    Rails.logger.info "[UAZAPI] Channel validated as Channel::Api with UazAPI: channel_id=#{@inbox.channel.id}"
  end

  def create_channel
    return unless allowed_channel_types.include?(permitted_params[:channel][:type])

    account_channels_method.create!(permitted_params(channel_type_from_params::EDITABLE_ATTRS)[:channel].except(:type))
  end

  def allowed_channel_types
    %w[web_widget api email line telegram whatsapp sms]
  end

  def update_inbox_working_hours
    @inbox.update_working_hours(params.permit(working_hours: Inbox::OFFISABLE_ATTRS)[:working_hours]) if params[:working_hours]
  end

  def update_channel
    channel_attributes = get_channel_attributes(@inbox.channel_type)
    return if permitted_params(channel_attributes)[:channel].blank?

    validate_and_update_email_channel(channel_attributes) if @inbox.inbox_type == 'Email'

    reauthorize_and_update_channel(channel_attributes)
    update_channel_feature_flags
  end

  def channel_update_required?
    permitted_params(get_channel_attributes(@inbox.channel_type))[:channel].present?
  end

  def validate_and_update_email_channel(channel_attributes)
    validate_email_channel(channel_attributes)
  rescue StandardError => e
    render json: { message: e }, status: :unprocessable_entity and return
  end

  def reauthorize_and_update_channel(channel_attributes)
    @inbox.channel.reauthorized! if @inbox.channel.respond_to?(:reauthorized!)
    @inbox.channel.update!(permitted_params(channel_attributes)[:channel])
  end

  def update_channel_feature_flags
    return unless @inbox.web_widget?
    return unless permitted_params(Channel::WebWidget::EDITABLE_ATTRS)[:channel].key? :selected_feature_flags

    @inbox.channel.selected_feature_flags = permitted_params(Channel::WebWidget::EDITABLE_ATTRS)[:channel][:selected_feature_flags]
    @inbox.channel.save!
  end

  def format_csat_config(config)
    {
      display_type: config['display_type'] || 'emoji',
      message: config['message'] || '',
      survey_rules: {
        operator: config.dig('survey_rules', 'operator') || 'contains',
        values: config.dig('survey_rules', 'values') || []
      }
    }
  end

  def inbox_attributes
    [:name, :avatar, :greeting_enabled, :greeting_message, :enable_email_collect, :csat_survey_enabled,
     :enable_auto_assignment, :working_hours_enabled, :out_of_office_message, :timezone, :allow_messages_after_resolved,
     :lock_to_single_conversation, :portal_id, :sender_name_type, :business_name,
     { csat_config: [:display_type, :message, { survey_rules: [:operator, { values: [] }] }] }]
  end

  def permitted_params(channel_attributes = [])
    # We will remove this line after fixing https://linear.app/chatwoot/issue/CW-1567/null-value-passed-as-null-string-to-backend
    params.each { |k, v| params[k] = params[k] == 'null' ? nil : v }

    params.permit(
      *inbox_attributes,
      channel: [:type, *channel_attributes]
    )
  end

  def channel_type_from_params
    {
      'web_widget' => Channel::WebWidget,
      'api' => Channel::Api,
      'email' => Channel::Email,
      'line' => Channel::Line,
      'telegram' => Channel::Telegram,
      'whatsapp' => Channel::Whatsapp,
      'sms' => Channel::Sms
    }[permitted_params[:channel][:type]]
  end

  def get_channel_attributes(channel_type)
    if channel_type.constantize.const_defined?(:EDITABLE_ATTRS)
      channel_type.constantize::EDITABLE_ATTRS.presence
    else
      []
    end
  end

  def whatsapp_channel?
    @inbox.whatsapp? || (@inbox.twilio? && @inbox.channel.whatsapp?)
  end

  def trigger_template_sync
    if @inbox.whatsapp?
      Channels::Whatsapp::TemplatesSyncJob.perform_later(@inbox.channel)
    elsif @inbox.twilio? && @inbox.channel.whatsapp?
      Channels::Twilio::TemplatesSyncJob.perform_later(@inbox.channel)
    end
  end
end

Api::V1::Accounts::InboxesController.prepend_mod_with('Api::V1::Accounts::InboxesController')
