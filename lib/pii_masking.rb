# Masks PII (phone / email) before it goes into a log line, keeping just enough to debug
# (country+area prefix and last 4 digits; first letter + domain) without exposing the full value.
# Use in Rails.logger calls that would otherwise print a customer's phone/email (LGPD minimization).
#
#   PiiMasking.mask_phone('+5549991234567') # => '+55499****4567'
#   PiiMasking.mask_email('joao@empresa.com') # => 'j***@empresa.com'
module PiiMasking
  module_function

  # Keep the leading '+' (if any) + first 5 digits and the last 4; mask the middle. Numbers too short
  # to keep both ends meaningfully are fully masked. Non-numeric input returns the mask.
  def mask_phone(value)
    str = value.to_s
    return str if str.blank?

    digits = str.gsub(/\D/, '')
    return '****' if digits.length < 8

    prefix = str.start_with?('+') ? '+' : ''
    "#{prefix}#{digits[0, 5]}****#{digits[-4, 4]}"
  end

  # Keep the first letter of the local part + the full domain; mask the rest. Non-emails are fully masked.
  def mask_email(value)
    str = value.to_s
    return str if str.blank?

    local, at, domain = str.partition('@')
    return '***' if at.blank? || domain.blank?

    "#{local[0]}***@#{domain}"
  end
end
