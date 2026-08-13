# Plan/Subscription scaffolding (Fase 1: só dados + gate, sem preços/billing/enforcement).
# Plan -> PlanFeature (toggles) + PlanLimit (numéricos); Account -> Subscription(s) + AiCreditBalance.
class CreatePlanSubscriptionTables < ActiveRecord::Migration[7.1]
  def change
    create_table :plans do |t|
      t.string  :name, null: false
      t.string  :slug, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :plans, :slug, unique: true

    # Feature toggle (liga/desliga) por plano.
    create_table :plan_features do |t|
      t.references :plan, null: false, foreign_key: true
      t.string  :key, null: false
      t.boolean :enabled, null: false, default: false
      t.timestamps
    end
    add_index :plan_features, [:plan_id, :key], unique: true

    # Limite numérico por plano. max_value NULL = ilimitado.
    create_table :plan_limits do |t|
      t.references :plan, null: false, foreign_key: true
      t.string  :key, null: false
      t.integer :max_value                            # null = ilimitado
      t.integer :overflow_behavior, null: false, default: 0 # hard_block:0 soft_warning:1 paid_overage:2
      t.integer :overage_price_cents                  # null; só relevante em paid_overage
      t.timestamps
    end
    add_index :plan_limits, [:plan_id, :key], unique: true

    # has_many em Account (histórico de trocas); a "atual" é derivada por scope.
    create_table :subscriptions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :plan, null: false, foreign_key: true
      t.integer  :status, null: false, default: 0     # active:0 trialing:1 canceled:2 past_due:3
      t.datetime :started_at
      t.datetime :ends_at                             # null = sem término
      t.timestamps
    end
    add_index :subscriptions, [:account_id, :status]

    # Saldo consumível de créditos de IA (separado do limite). 1 por conta.
    create_table :ai_credit_balances do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.integer :plan_credits, null: false, default: 0  # renovado no ciclo (valor vem do plano)
      t.integer :extra_credits, null: false, default: 0 # comprados avulsos, não expiram
      t.timestamps
    end
  end
end
