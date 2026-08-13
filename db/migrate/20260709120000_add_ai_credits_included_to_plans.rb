# Créditos de IA incluídos no plano (billing Fase 2 — renovação de plan_credits no ciclo).
# Ai::CreditsRenewalJob reseta AiCreditBalance#plan_credits para este valor a cada aniversário.
# Valores por plano vêm do seed (plans:seed): START=500, STANDARD=1000, PRO=1000, interno=999999.
class AddAiCreditsIncludedToPlans < ActiveRecord::Migration[7.1]
  def change
    add_column :plans, :ai_credits_included, :integer, null: false, default: 0
  end
end
