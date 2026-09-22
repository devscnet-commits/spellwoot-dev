# Régua ÚNICA de mascaramento de segredo em resposta HTTP. Existia só dentro do
# IntegrationSettingsController, e o caminho legado de integrations_hooks — que grava a mesma chave
# da OpenAI em outra tabela — nunca soube dela: despejava `settings` cru no jbuilder. Ter as duas
# réguas no mesmo lugar é o que impede a divergência de voltar.
#
# Mostra prefixo e sufixo para o dono do segredo reconhecer qual cadastrou, nunca o suficiente para
# reconstruir. O comprimento do asterisco é FIXO, então o tamanho real não vaza junto.
module SecretMaskingHelper
  # camelCase (Hub de Integrações) e snake_case (hooks legados/apps.yml) na mesma lista.
  SECRET_KEY_NAMES = %w[
    accessToken apiKey clientSecret refreshToken authToken token
    access_key api_key secret_key client_secret refresh_token access_token credentials password
  ].freeze

  module_function

  def secret_key_name?(key)
    SECRET_KEY_NAMES.include?(key.to_s)
  end

  # Segredo curto demais para prefixo+sufixo seria entregue quase inteiro (4+3 caracteres cobrem
  # tudo de um valor de 7), então abaixo desse limite não se mostra caractere nenhum.
  def mask_secret(value)
    text = value.to_s
    return '*' * 24 if text.length <= 8

    "#{text.first(4)}#{'*' * 20}#{text.last(3)}"
  end

  def mask_secret_values(hash)
    (hash || {}).each_with_object({}) do |(key, value), masked|
      masked[key] = secret_key_name?(key) && value.present? ? mask_secret(value) : value
    end
  end
end
