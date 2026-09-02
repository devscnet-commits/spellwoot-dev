class Whatsapp::MessageTemplateValidator
  NAME_REGEX = /\A[a-z0-9_]+\z/
  ALLOWED_CATEGORIES = %w[MARKETING UTILITY AUTHENTICATION].freeze
  # QUICK_REPLY, URL, PHONE_NUMBER and COPY_CODE are valid for both Marketing and Utility templates,
  # so no category-conditional split is needed here yet. CATALOG, FLOW and ORDER_DETAILS are
  # Marketing-only, enforced by the builder UI (only offered under their matching subtype) and by
  # EXCLUSIVE_BUTTON_TYPES below, since Meta requires each to be the template's only button.
  # call_permission_request (params[:call_permission_request]) isn't a button at all — it's a
  # separate CALL_PERMISSION_REQUEST template component, validated by call_permission_request_error.
  ALLOWED_BUTTON_TYPES = %w[QUICK_REPLY URL PHONE_NUMBER COPY_CODE CATALOG FLOW ORDER_DETAILS].freeze
  EXCLUSIVE_BUTTON_TYPES = %w[CATALOG FLOW ORDER_DETAILS].freeze
  ALLOWED_HEADER_TYPES = %w[NONE TEXT IMAGE VIDEO DOCUMENT].freeze
  CALL_PERMISSION_REQUEST_HEADER_TYPES = %w[NONE TEXT].freeze
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
      call_permission_request_error,
      *button_errors
    ].compact
  end

  private

  def call_permission_request?
    ActiveModel::Type::Boolean.new.cast(@params[:call_permission_request])
  end

  def call_permission_request_error
    return unless call_permission_request?
    return 'O cabeçalho de um modelo de solicitação de permissão de ligação deve ser Texto ou estar ausente' unless CALL_PERMISSION_REQUEST_HEADER_TYPES.include?(header_type)
    return 'Um modelo de solicitação de permissão de ligação não pode ter botões' if @params[:buttons].present?
  end

  def header_type
    @params[:header]&.[](:type) || 'NONE'
  end

  def header_error
    header = @params[:header]
    return if header.blank? || header[:type].blank? || header[:type] == 'NONE'
    return "O tipo de cabeçalho deve ser um dos seguintes: #{ALLOWED_HEADER_TYPES.join(', ')}" unless ALLOWED_HEADER_TYPES.include?(header[:type])

    header[:type] == 'TEXT' ? header_text_error(header) : header_media_error(header)
  end

  def header_text_error(header)
    text = header[:text].to_s
    return 'O texto do cabeçalho é obrigatório' if text.blank?
    return "O texto do cabeçalho deve ter no máximo #{MAX_HEADER_TEXT_LENGTH} caracteres" if text.length > MAX_HEADER_TEXT_LENGTH
  end

  def header_media_error(header)
    'A mídia do cabeçalho é obrigatória — envie um arquivo primeiro' if header[:handle].blank?
  end

  def name_error
    name = @params[:name].to_s
    return 'O nome é obrigatório' if name.blank?
    return 'O nome deve conter apenas letras minúsculas, números e underline' unless name.match?(NAME_REGEX)
  end

  def category_error
    return if ALLOWED_CATEGORIES.include?(@params[:category])

    "A categoria deve ser uma das seguintes: #{ALLOWED_CATEGORIES.join(', ')}"
  end

  def body_error
    body = @params[:body].to_s
    return 'O corpo da mensagem é obrigatório' if body.blank?
    return "O corpo da mensagem deve ter no máximo #{MAX_BODY_LENGTH} caracteres" if body.length > MAX_BODY_LENGTH
    return 'O corpo da mensagem não pode começar ou terminar com uma variável' if dangling_variable?(body)

    variable_sample_error(body)
  end

  def dangling_variable?(body)
    body.match?(/\A\{\{\d+\}\}/) || body.match?(/\{\{\d+\}\}\z/)
  end

  def variable_sample_error(body)
    numbers = self.class.body_variable_numbers(body)
    return if numbers.empty?
    return 'As variáveis devem ser sequenciais a partir de {{1}} (ex: {{1}}, {{2}})' unless numbers == (1..numbers.size).to_a

    sample_values = @params[:body_sample_values] || []
    return "Informe um valor de exemplo para cada variável (#{numbers.size} esperado(s))" if sample_values.size != numbers.size
    return 'Os valores de exemplo não podem ficar em branco' if sample_values.any?(&:blank?)
  end

  def footer_error
    footer = @params[:footer]
    return if footer.blank?
    return "O rodapé deve ter no máximo #{MAX_FOOTER_LENGTH} caracteres" if footer.length > MAX_FOOTER_LENGTH
  end

  def button_errors
    buttons = @params[:buttons] || []
    return ["Um modelo pode ter no máximo #{MAX_BUTTONS} botões"] if buttons.size > MAX_BUTTONS

    error = exclusive_button_error(buttons)
    return [error] if error

    buttons.filter_map { |button| button_error(button) }
  end

  def exclusive_button_error(buttons)
    exclusive_button = buttons.find { |button| EXCLUSIVE_BUTTON_TYPES.include?(button[:type]) }
    return if exclusive_button.blank?

    "Um botão do tipo #{exclusive_button[:type]} precisa ser o único botão do modelo" if buttons.size > 1
  end

  def button_error(button)
    type = button[:type]
    return "O tipo de botão #{type} não é suportado" unless ALLOWED_BUTTON_TYPES.include?(type)

    text = button[:text].to_s
    return "O texto do botão é obrigatório para botões do tipo #{type}" if text.blank?
    return "O texto do botão deve ter no máximo #{MAX_BUTTON_TEXT_LENGTH} caracteres" if text.length > MAX_BUTTON_TEXT_LENGTH

    button_field_error(button)
  end

  def button_field_error(button)
    case button[:type]
    when 'URL'
      'A URL do botão é obrigatória' if button[:url].blank?
    when 'PHONE_NUMBER'
      phone_number_error(button[:phone_number])
    when 'COPY_CODE'
      'O código de exemplo do botão é obrigatório' if button[:example].blank?
    when 'FLOW'
      'O ID do Flow do botão é obrigatório' if button[:flow_id].blank?
    end
  end

  def phone_number_error(phone_number)
    return 'O número de telefone do botão é obrigatório' if phone_number.blank?
    return "O número de telefone do botão deve ter no máximo #{MAX_BUTTON_PHONE_LENGTH} caracteres" if phone_number.length > MAX_BUTTON_PHONE_LENGTH
  end
end
