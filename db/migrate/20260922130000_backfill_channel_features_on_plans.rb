# Os canais viraram features de plano (Plan::PLAN_FEATURE_TO_ACCOUNT_FLAG) e ganharam enforcement de
# servidor (ChannelAvailability). Sem este backfill o deploy seria destrutivo: sync_features_to! faz
# disable_features de TODA chave gerenciada que o plano não declare, e nenhum plano declara as novas
# — na primeira renovação de ciclo toda conta perderia WhatsApp, Instagram, e-mail, API, Telegram e
# SMS de uma vez.
#
# Preserva o estado de hoje: esses canais são globalmente disponíveis, então todo plano existente
# passa a declará-los LIGADOS. Restringir por plano vira decisão explícita na tela do Super Admin,
# não efeito colateral de um deploy.
class BackfillChannelFeaturesOnPlans < ActiveRecord::Migration[7.1]
  PLAN_KEYS = %w[whatsapp_channel instagram_channel email_channel api_channel telegram_channel sms_channel].freeze
  ACCOUNT_FLAGS = %w[channel_whatsapp channel_instagram channel_email channel_api channel_telegram channel_sms].freeze

  def up
    Plan.find_each do |plan|
      PLAN_KEYS.each do |key|
        feature = plan.plan_features.find_or_initialize_by(key: key)
        # Só grava linha NOVA: se alguém já configurou esta chave, a decisão dele vale.
        feature.update!(enabled: true) if feature.new_record?
      end
    end

    # Featurable só aplica o default de config/features.yml no before_create, então conta existente
    # não tem os bits novos (channel_telegram e channel_sms nem existiam como flag). Mesmo remédio da
    # BackfillPlanManagedChannelFlags, pelo mesmo motivo: não barrar quem já usa o sistema hoje.
    Account.find_each { |account| account.enable_features!(*ACCOUNT_FLAGS) }
  end

  def down
    Plan.find_each { |plan| plan.plan_features.where(key: PLAN_KEYS).destroy_all }
    # Não mexe nos bits das contas: não dá para distinguir o que esta migration ligou do que já
    # estava ligado antes.
  end
end
