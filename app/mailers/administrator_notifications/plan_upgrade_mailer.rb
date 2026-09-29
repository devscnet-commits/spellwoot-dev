# Pedido de upgrade de plano feito pelo cliente na tela Meu Plano quando não há WhatsApp de upgrade
# configurado (PLAN_UPGRADE_WHATSAPP_NUMBER). Vai para o admin da PLATAFORMA (Conexiia), mesmo destino das
# solicitações de crédito (AdministratorNotifications::CreditRequestMailer). O plano NÃO muda aqui: a equipe
# combina o pagamento e troca o plano no Super Admin.
class AdministratorNotifications::PlanUpgradeMailer < AdministratorNotifications::BaseMailer
  # Há para quem mandar? Sem isso a tela não oferece o pedido por e-mail (orienta falar com o suporte).
  def self.contact_configured?
    instance_admin_email.present?
  end

  def self.instance_admin_email
    GlobalConfig.get('CHATWOOT_INSTANCE_ADMIN_EMAIL')['CHATWOOT_INSTANCE_ADMIN_EMAIL']
  end

  def new_request(account, user, current_plan, target_plan)
    return unless self.class.contact_configured?

    meta = {
      'instance_url' => ENV.fetch('FRONTEND_URL', 'not available'),
      'account_id' => account.id,
      'account_name' => account.name,
      'requested_by' => user&.name,
      'requested_by_email' => user&.email,
      'current_plan' => current_plan&.name,
      'target_plan' => target_plan.name,
      'requested_at' => Time.current.strftime('%d/%m/%Y %H:%M')
    }
    subject = "[Conexiia] Pedido de upgrade de plano — conta ##{account.id} (#{account.name})"
    action_url = "#{ENV.fetch('FRONTEND_URL', nil)}/super_admin/accounts/#{account.id}"
    send_notification(subject, to: self.class.instance_admin_email, action_url: action_url, meta: meta)
  end
end
