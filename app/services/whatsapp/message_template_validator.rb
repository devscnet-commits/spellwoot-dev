class Whatsapp::MessageTemplateValidator
  NAME_REGEX = /\A[a-z0-9_]+\z/
  ALLOWED_CATEGORIES = %w[MARKETING UTILITY AUTHENTICATION].freeze
  # QUICK_REPLY, URL, PHONE_NUMBER and COPY_CODE are valid for both Marketing and Utility templates,
  # so no category-conditional split is needed here yet. FLOW, CATALOG and voice-call permission
  # buttons are Marketing-only additions the builder doesn't support until that UI ships.
  ALLOWED_BUTTON_TYPES = %w[QUICK_REPLY URL PHONE_NUMBER COPY_CODE].freeze
  ALLOWED_HEADER_TYPES = %w[NONE TEXT IMAGE VIDEO DOCUMENT].freeze
  MAX_HEADER_TEXT_LENGTH = 60
  MAX_BODY_LENGTH = 1024
  MAX_FOOTER_LENGTH = 60
  MAX_BUTTON_TEXT_LENGTH = 25
  MAX_BUTTON_PHONE_LENGTH = 20
  MAX_BUTTONS = 10

  def self.body_variable_numbers(body)
    body.to_s.scan(/\{\{(\d+)\}\}/).flatten.map(&:to_i).uniq.sort
  end

  # require_name: false for edits — Meta's template update endpoint only accepts category and
  # components, the name can't be changed after creation.
  def initialize(params, require_name: true)
    @params = params
    @require_name = require_name
  end

  def valid?
    errors.empty?
  end

  def errors
    @errors ||= [
      (name_error if @require_name),
      category_error,
      header_error,
      body_error,
      footer_error,
      *button_errors
    ].compact
  end

  private

  def header_error
    header = @params[:header]
    return if header.blank? || header[:type].blank? || header[:type] == 'NONE'
    return "Header type must be one of #{ALLOWED_HEADER_TYPES.join(', ')}" unless ALLOWED_HEADER_TYPES.include?(header[:type])

    header[:type] == 'TEXT' ? header_text_error(header) : header_media_error(header)
  end

  def header_text_error(header)
    text = header[:text].to_s
    return 'Header text is required' if text.blank?
    return "Header text must be #{MAX_HEADER_TEXT_LENGTH} characters or fewer" if text.length > MAX_HEADER_TEXT_LENGTH
  end

  def header_media_error(header)
    'Header media is required — upload a file first' if header[:handle].blank?
  end

  def name_error
    name = @params[:name].to_s
    return 'Name is required' if name.blank?
    return 'Name must contain only lowercase letters, numbers, and underscores' unless name.match?(NAME_REGEX)
  end

  def category_error
    return if ALLOWED_CATEGORIES.include?(@params[:category])

    "Category must be one of #{ALLOWED_CATEGORIES.join(', ')}"
  end

  def body_error
    body = @params[:body].to_s
    return 'Body is required' if body.blank?
    return "Body must be #{MAX_BODY_LENGTH} characters or fewer" if body.length > MAX_BODY_LENGTH
    return 'Body cannot start or end with a variable' if dangling_variable?(body)

    variable_sample_error(body)
  end

  def dangling_variable?(body)
    body.match?(/\A\{\{\d+\}\}/) || body.match?(/\{\{\d+\}\}\z/)
  end

  def variable_sample_error(body)
    numbers = self.class.body_variable_numbers(body)
    return if numbers.empty?
    return 'Variables must be sequential starting at {{1}} (e.g. {{1}}, {{2}})' unless numbers == (1..numbers.size).to_a

    sample_values = @params[:body_sample_values] || []
    return "Provide a sample value for each variable (#{numbers.size} expected)" if sample_values.size != numbers.size
    return 'Sample values cannot be blank' if sample_values.any?(&:blank?)
  end

  def footer_error
    footer = @params[:footer]
    return if footer.blank?
    return "Footer must be #{MAX_FOOTER_LENGTH} characters or fewer" if footer.length > MAX_FOOTER_LENGTH
  end

  def button_errors
    buttons = @params[:buttons] || []
    return ["A template can have at most #{MAX_BUTTONS} buttons"] if buttons.size > MAX_BUTTONS

    buttons.filter_map { |button| button_error(button) }
  end

  def button_error(button)
    type = button[:type]
    return "Button type #{type} is not supported" unless ALLOWED_BUTTON_TYPES.include?(type)

    text = button[:text].to_s
    return "Button text is required for #{type} buttons" if text.blank?
    return "Button text must be #{MAX_BUTTON_TEXT_LENGTH} characters or fewer" if text.length > MAX_BUTTON_TEXT_LENGTH

    button_field_error(button)
  end

  def button_field_error(button)
    case button[:type]
    when 'URL'
      'Button URL is required' if button[:url].blank?
    when 'PHONE_NUMBER'
      phone_number_error(button[:phone_number])
    when 'COPY_CODE'
      'Button example code is required' if button[:example].blank?
    end
  end

  def phone_number_error(phone_number)
    return 'Button phone number is required' if phone_number.blank?
    return "Button phone number must be #{MAX_BUTTON_PHONE_LENGTH} characters or fewer" if phone_number.length > MAX_BUTTON_PHONE_LENGTH
  end
end
