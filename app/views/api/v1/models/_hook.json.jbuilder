json.id resource.id
json.app_id resource.app_id
json.status resource.enabled?
json.inbox resource.inbox&.slice(:id, :name)
json.account_id resource.account_id
json.hook_type resource.hook_type

# `settings` é jsonb NÃO criptografado (só access_token é, no model) e guardava a chave da OpenAI
# em texto puro no caminho legado — voltava inteira nesta resposta. Mesma régua do Hub.
json.settings mask_secret_values(resource.settings) if Current.account_user&.administrator?
json.reference_id resource.reference_id if Current.account_user&.administrator?
