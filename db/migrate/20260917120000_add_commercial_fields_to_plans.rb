# Campos comerciais confirmados na Planos_Conexi_v2 (Fase 1): visibilidade no painel, plano
# cortesia (flag setada manualmente, não self-service) e o preço do crédito extra de IA. Os demais
# (annual/promo) ficam nil até os valores por plano serem informados — a estrutura só precisa existir.
class AddCommercialFieldsToPlans < ActiveRecord::Migration[7.1]
  def change
    add_column :plans, :visible_to_new_subscribers, :boolean, null: false, default: true
    add_column :plans, :courtesy, :boolean, null: false, default: false
    add_column :plans, :description, :text
    add_column :plans, :annual_price_cents, :integer
    add_column :plans, :promo_price_cents, :integer
    add_column :plans, :promo_months_count, :integer
    add_column :plans, :ai_credit_overage_price_cents, :integer
  end
end
