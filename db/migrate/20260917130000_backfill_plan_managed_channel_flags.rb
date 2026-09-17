# channel_whatsapp/channel_api/webhook_api passaram a ter enforcement de fato na Fase 3 (criação de
# inbox WhatsApp/API, criação de Webhook). Featurable só aplica o default de features.yml em
# before_create — contas criadas ANTES desta migration não têm esses bits no feature_flags. Sem
# isto, qualquer conta existente que tentasse criar um 2º canal WhatsApp/API ou um webhook novo
# seria bloqueada por engano assim que este deploy fosse ao ar. A intenção é restringir só quem tiver
# Subscription ligada a um plano que não inclua o módulo — não afetar quem já usa o sistema hoje.
class BackfillPlanManagedChannelFlags < ActiveRecord::Migration[7.1]
  def up
    Account.find_each do |account|
      account.enable_features!('channel_whatsapp', 'channel_api', 'webhook_api')
    end
  end

  def down
    # Não reverte: não dá pra distinguir contas que já tinham essas flags manualmente ligadas antes
    # desta migration das que ela ligou.
  end
end
