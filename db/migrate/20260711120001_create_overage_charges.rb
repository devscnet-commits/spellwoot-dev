# Cobrança de excedente do ciclo (billing Fase 2). Gerada pela Ai::CreditsRenewalJob no fim do ciclo:
# total_cents = média dos OverageSnapshot do período × overage_price_cents do PlanLimit.
# status pending = aguardando cobrança manual (SEM Stripe/Asaas ainda — Fase 3).
class CreateOverageCharges < ActiveRecord::Migration[7.1]
  def change
    create_table :overage_charges do |t|
      t.references :account, null: false, foreign_key: true
      t.references :subscription, null: false, foreign_key: true
      t.string   :plan_limit_key, null: false
      t.datetime :cycle_start
      t.datetime :cycle_end
      t.decimal  :average_excess, precision: 10, scale: 2
      t.integer  :unit_price_cents
      t.integer  :total_cents
      t.integer  :status, null: false, default: 0 # pending:0 invoiced:1
      t.timestamps
    end
  end
end
