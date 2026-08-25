# Preço do plano (billing). Estrutura apenas — valores provisórios, NÃO populados no seed ainda
# (aguardando confirmação oficial da planilha Planos_Conexi_v2). Ambos nullable:
#   monthly_price_cents = mensalidade; nil = não definido.
#   setup_fee_cents     = taxa de implantação; nil = não definido (0 significaria "grátis").
# Projeto é BRL-only — sem campo de moeda por ora. overage_price_cents (plan_limits) é outro campo,
# não mexido aqui.
class AddPriceFieldsToPlans < ActiveRecord::Migration[7.1]
  def change
    add_column :plans, :monthly_price_cents, :integer
    add_column :plans, :setup_fee_cents, :integer
  end
end
