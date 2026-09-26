# WhatsApp não oficial (UazAPI/Evolution) virou sub-opção do módulo WhatsApp no plano. Hoje todo plano
# que libera WhatsApp libera também os provedores não oficiais (não havia gate nenhum na rota deles),
# então a linha nova nasce com o MESMO valor de whatsapp_channel: nenhum cliente perde o que já usa.
# Um plano "só oficiais" passa a ser decisão explícita na tela do Super Admin.
class BackfillWhatsappUnofficialChannel < ActiveRecord::Migration[7.1]
  def up
    Plan.find_each do |plan|
      feature = plan.plan_features.find_or_initialize_by(key: 'whatsapp_unofficial_channel')
      feature.update!(enabled: plan.feature_enabled?('whatsapp_channel')) if feature.new_record?
    end

    # Featurable só aplica o default de features.yml no before_create — conta existente não tem o bit.
    Account.find_each { |account| account.enable_features!('channel_whatsapp_unofficial') }
  end

  def down
    Plan.find_each { |plan| plan.plan_features.where(key: 'whatsapp_unofficial_channel').destroy_all }
  end
end
