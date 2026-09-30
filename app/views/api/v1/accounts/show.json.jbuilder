json.partial! 'api/v1/models/account', formats: [:json], resource: @account
json.latest_chatwoot_version @latest_chatwoot_version
# Módulo "Token de acesso pessoal (API)" do plano — a tela de perfil só mostra o token quando liberado.
json.api_user_token_allowed Billing::PlanModules.allowed?(@account, 'api_user_token')
json.partial! 'enterprise/api/v1/accounts/partials/account', account: @account if ChatwootApp.enterprise?
