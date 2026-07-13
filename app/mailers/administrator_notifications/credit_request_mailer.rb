# Notifica o admin da PLATAFORMA (SCNET) quando um cliente solicita mais créditos de IA (billing
# Fase 1). Mira o CHATWOOT_INSTANCE_ADMIN_EMAIL (mesmo padrão do AccountComplianceMailer), não os
# admins da conta. O template só usa meta.* (independe de Current.account no job assíncrono).
class AdministratorNotifications::CreditRequestMailer < AdministratorNotifications::BaseMailer
  def new_request(credit_request)
    return if instance_admin_email.blank?

    account = credit_request.account
    subject = "[SCNET] Solicitação de créditos de IA — conta ##{account.id} (#{account.name})"

    send_notification(subject, to: instance_admin_email, action_url: super_admin_url, meta: build_meta(credit_request, account))
  end

  # Aviso PROATIVO (billing Fase 2): o saldo de créditos de IA da conta chegou a <=10% do teto do
  # plano. Mesmo mecanismo (mira o admin da plataforma), dando tempo de agir antes de esgotar.
  def low_balance_warning(account, remaining, cap)
    return if instance_admin_email.blank?

    subject = "[SCNET] Saldo de créditos de IA baixo — conta ##{account.id} (#{account.name})"
    meta = {
      'instance_url' => instance_url,
      'account_id' => account.id,
      'account_name' => account.name,
      'remaining' => remaining,
      'cap' => cap,
      'percentage_used' => cap.to_i.positive? ? (100 - (remaining.to_f / cap * 100)).round : nil
    }

    send_notification(subject, to: instance_admin_email, action_url: super_admin_url, meta: meta)
  end

  private

  def build_meta(credit_request, account)
    {
      'instance_url' => instance_url,
      'account_id' => account.id,
      'account_name' => account.name,
      'requested_by' => credit_request.requested_by&.name,
      'requested_by_email' => credit_request.requested_by&.email,
      'amount_requested' => credit_request.amount_requested,
      'reason' => credit_request.reason.presence || 'não informado',
      'requested_at' => credit_request.created_at&.strftime('%d/%m/%Y %H:%M')
    }
  end

  def instance_admin_email
    GlobalConfig.get('CHATWOOT_INSTANCE_ADMIN_EMAIL')['CHATWOOT_INSTANCE_ADMIN_EMAIL']
  end

  def instance_url
    ENV.fetch('FRONTEND_URL', 'not available')
  end

  def super_admin_url
    "#{ENV.fetch('FRONTEND_URL', nil)}/super_admin/credit_requests"
  end
end
