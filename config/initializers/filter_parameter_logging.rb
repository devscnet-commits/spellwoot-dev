# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
# A comparação do ParameterFilter é por SUBSTRING, sem diferenciar maiúsculas. Por isso ':_key' pega
# 'api_key' mas NÃO pega 'apiKey': não há underline no meio. O Hub de Integrações grava justamente em
# camelCase, então a chave de IA de cada cliente saía em texto puro na linha "Parameters:" de todo
# save. Os outros segredos camelCase do formulário já eram pegos por tabela: accessToken, authToken e
# refreshToken pelo regex de 'token' abaixo, clientSecret por ':secret' — 'apiKey' era o único sem
# cobertura. ':apikey' fecha as duas grafias de uma vez.
Rails.application.config.filter_parameters += [
  :password, :secret, :_key, :apikey, :auth, :crypt, :salt, :certificate, :otp, :access, :private, :protected, :ssn,
  :otp_secret, :otp_code, :backup_code, :mfa_token, :otp_backup_codes
]

# Regex to filter all occurrences of 'token' in keys except for 'website_token'
filter_regex = /\A(?!.*\bwebsite_token\b).*token/i

# Apply the regex for filtering
Rails.application.config.filter_parameters += [filter_regex]
