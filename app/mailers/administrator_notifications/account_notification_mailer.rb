class AdministratorNotifications::AccountNotificationMailer < AdministratorNotifications::BaseMailer
  def account_deletion_user_initiated(account, reason)
    subject = 'Your Chatwoot account deletion has been scheduled'
    action_url = settings_url('general')
    meta = {
      'account_name' => account.name,
      'deletion_date' => format_deletion_date(account.custom_attributes['marked_for_deletion_at']),
      'reason' => reason
    }

    send_notification(subject, action_url: action_url, meta: meta)
  end

  def account_deletion_for_inactivity(account, reason)
    subject = 'Your Chatwoot account is scheduled for deletion due to inactivity'
    action_url = settings_url('general')
    meta = {
      'account_name' => account.name,
      'deletion_date' => format_deletion_date(account.custom_attributes['marked_for_deletion_at']),
      'reason' => reason
    }

    send_notification(subject, action_url: action_url, meta: meta)
  end

  def contact_import_complete(resource)
    subject = 'Contact Import Completed'

    action_url = if resource.failed_records.attached?
                   Rails.application.routes.url_helpers.rails_blob_url(resource.failed_records)
                 else
                   "#{ENV.fetch('FRONTEND_URL', nil)}/app/accounts/#{resource.account.id}/contacts"
                 end

    meta = {
      'failed_contacts' => resource.total_records - resource.processed_records,
      'imported_contacts' => resource.processed_records
    }

    send_notification(subject, action_url: action_url, meta: meta)
  end

  def contact_import_failed
    subject = 'Contact Import Failed'
    send_notification(subject)
  end

  def contact_export_complete(file_url, email_to)
    subject = "Your contact's export file is available to download."
    send_notification(subject, to: email_to, action_url: file_url)
  end

  def automation_rule_disabled(rule)
    subject = 'Automation rule disabled due to validation errors.'
    action_url = settings_url('automation/list')
    meta = { 'rule_name' => rule.name }

    send_notification(subject, action_url: action_url, meta: meta)
  end

  # Handoff da IA sem agente atribuível: o time de destino não tem membro disponível e a conversa
  # ficou sem dono. Avisa os admins da conta (destinatário padrão do send_notification) para corrigir
  # a composição do time. Disparado por Ai::HandoffCoordinator#alert_no_assignable_member.
  def handoff_no_agent_available(conversation, team_name)
    subject = "Conversa sem agente disponível — o time \"#{team_name}\" não tem ninguém para atender"
    action_url = "#{ENV.fetch('FRONTEND_URL', nil)}/app/accounts/#{conversation.account_id}/conversations/#{conversation.display_id}"
    meta = {
      'team_name' => team_name,
      'conversation_id' => conversation.display_id,
      'account_name' => conversation.account.name
    }

    send_notification(subject, action_url: action_url, meta: meta)
  end

  # Fase 2: provedor de IA indisponível (cota/billing/rate-limit) resultou em handoff automático. Erro de
  # cota é problema de quem PAGA, não do atendente — avisa os admins da conta (destinatário padrão) para
  # que verifiquem o provedor antes que mais conversas caiam no humano. Disparado (throttled, 1x/hora por
  # provedor) por Ai::Gateway#notify_admin_provider_error. Linguagem de dono, não de log.
  # SEGURANÇA: recebe SÓ o nome do provedor — nunca a chave de API nem a mensagem crua do provedor (que
  # pode conter credencial). A "sanitização" aqui é por OMISSÃO: o motivo técnico não entra no e-mail.
  def provider_error_handoff(account, provider)
    subject = "IA indisponível: o provedor \"#{provider}\" falhou e as conversas estão indo para atendimento humano"
    action_url = settings_url('billing')
    meta = {
      'provider' => provider,
      'account_name' => account.name
    }

    send_notification(subject, action_url: action_url, meta: meta)
  end

  private

  def format_deletion_date(deletion_date_str)
    return 'Unknown' if deletion_date_str.blank?

    Time.zone.parse(deletion_date_str).strftime('%B %d, %Y')
  rescue StandardError
    'Unknown'
  end
end
