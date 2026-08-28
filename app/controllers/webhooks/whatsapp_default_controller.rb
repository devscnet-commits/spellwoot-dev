# Meta requires a WhatsApp Cloud API app to already be subscribed to receive
# messages before a per-client override_callback_uri call (used right after
# embedded signup) is allowed -- without any default webhook configured on
# the app itself, every embedded signup hits error #100.
#
# This is that app-level default: a fixed, account-agnostic placeholder
# webhook configured once in the Meta App Dashboard (WhatsApp > Configuration).
# Chatwoot always overrides the callback to the per-number endpoint right
# after embedded signup succeeds, so this endpoint should rarely see real
# traffic -- it only needs to verify and no-op.
class Webhooks::WhatsappDefaultController < ActionController::API
  include MetaTokenVerifyConcern

  def process_payload
    head :ok
  end

  private

  def valid_token?(token)
    expected_token = GlobalConfigService.load('WHATSAPP_DEFAULT_WEBHOOK_VERIFY_TOKEN', '')
    token.present? && expected_token.present? && token == expected_token
  end
end
