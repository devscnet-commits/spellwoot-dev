# Extração DETERMINÍSTICA de um slot a partir do texto do cliente, pelo tipo declarado (collect.type).
# É a rede de segurança (Camada A) do avanço-por-slot: preenche cpf/email/phone/number/choice SEM
# depender de o modelo devolver `attributes`. Texto livre (type=text, ex.: nome) é ambíguo -> NÃO
# extrai (fica com o modelo + fallback por turnos da Camada B). Retorna o valor normalizado ou nil.
class Ai::SlotExtractor
  CPF_RE = /\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b/
  EMAIL_RE = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
  # Telefone BR: +55 opcional, DDD (2 díg, com/sem parênteses), 8-9 díg com separador livre.
  PHONE_RE = /(?:\+?55[\s-]?)?\(?\d{2}\)?[\s-]?\d{4,5}[\s-]?\d{4}/
  NUMBER_RE = /-?\d+(?:[.,]\d+)?/

  def self.extract(attribute_type:, text:, options: nil)
    txt = text.to_s
    return nil if txt.strip.empty?

    # text e tipos desconhecidos: nil (ambíguo, não extrai).
    case attribute_type.to_s
    when 'cpf' then extract_cpf(txt)
    when 'email' then extract_email(txt)
    when 'phone' then extract_phone(txt)
    when 'number' then extract_number(txt)
    when 'choice' then extract_choice(txt, options)
    end
  end

  # CPF válido (com/sem pontuação): valida os 2 dígitos verificadores e rejeita sequências repetidas.
  # Retorna formatado (000.000.000-00).
  def self.extract_cpf(text)
    m = text.match(CPF_RE)
    return nil unless m

    digits = m[0].gsub(/\D/, '')
    return nil unless valid_cpf?(digits)

    "#{digits[0..2]}.#{digits[3..5]}.#{digits[6..8]}-#{digits[9..10]}"
  end

  def self.extract_email(text)
    m = text.match(EMAIL_RE)
    m && m[0].downcase
  end

  # Telefone BR normalizado só com dígitos (DDD + número, 10 ou 11). Descarta o 55 do país.
  def self.extract_phone(text)
    m = text.match(PHONE_RE)
    return nil unless m

    digits = m[0].gsub(/\D/, '')
    digits = digits[2..] if digits.length > 11 && digits.start_with?('55')
    digits if digits.length.between?(10, 11)
  end

  # Primeiro inteiro/decimal do texto; vírgula decimal vira ponto.
  def self.extract_number(text)
    m = text.match(NUMBER_RE)
    m && m[0].tr(',', '.')
  end

  # Casa o texto contra as options declaradas (insensível a caixa/acento/espaço). Retorna a option
  # CANÔNICA (como cadastrada), não o texto do cliente. Opções mais longas primeiro para evitar que
  # uma opção curta ("5") case dentro de outra ("5 a 10") quando o cliente disse a longa.
  def self.extract_choice(text, options)
    norm = normalize(text)
    Array(options).map(&:to_s).reject { |o| normalize(o).empty? }
                  .sort_by { |o| -normalize(o).length }
                  .find { |opt| norm.include?(normalize(opt)) }
  end

  # Dígitos verificadores do CPF (rejeita todos-iguais como 000... / 111...).
  def self.valid_cpf?(digits)
    return false unless digits.length == 11
    return false if digits.chars.uniq.size == 1

    [9, 10].all? { |pos| digits[pos].to_i == cpf_check_digit(digits, pos) }
  end

  def self.cpf_check_digit(digits, pos)
    weight = pos + 1
    sum = (0...pos).sum { |i| digits[i].to_i * (weight - i) }
    rest = (sum * 10) % 11
    rest == 10 ? 0 : rest
  end

  # Normaliza para comparação: minúsculas, sem acento (NFD sem marcas), espaços colapsados.
  def self.normalize(str)
    str.to_s.downcase.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').gsub(/\s+/, ' ').strip
  end
end
