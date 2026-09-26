# Preços são gravados em centavos (inteiro), mas no Super Admin são digitados e lidos em reais.
# Aceita "8", "8,5", "8,50", "1.234,56" (formato brasileiro) e também "8.50".
module MoneyCents
  def self.parse(value)
    text = value.to_s.delete('R$ ').strip
    return nil if text.empty?

    text = text.include?(',') ? text.delete('.').tr(',', '.') : text
    amount = BigDecimal(text, exception: false)
    amount && (amount * 100).round.to_i
  end

  def self.format(cents)
    return nil if cents.nil?

    whole, fraction = (cents.to_i.abs.divmod(100))
    formatted = "#{whole.to_s.reverse.scan(/\d{1,3}/).join('.').reverse},#{fraction.to_s.rjust(2, '0')}"
    cents.negative? ? "-#{formatted}" : formatted
  end
end
