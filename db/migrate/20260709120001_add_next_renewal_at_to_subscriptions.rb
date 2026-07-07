# Marco do próximo ciclo de renovação (mensal, ancorado no aniversário da assinatura).
# Ai::CreditsRenewalJob renova as assinaturas ativas cujo next_renewal_at já venceu.
# Backfill: assinaturas ativas já existentes (ex.: as 3 contas internas seedadas na Fase 2)
# ganham (started_at || NOW) + 1 mês para não ficarem sem ciclo.
class AddNextRenewalAtToSubscriptions < ActiveRecord::Migration[7.1]
  def up
    add_column :subscriptions, :next_renewal_at, :datetime

    execute(<<~SQL.squish)
      UPDATE subscriptions
      SET next_renewal_at = COALESCE(started_at, NOW()) + INTERVAL '1 month'
      WHERE status = 0 AND next_renewal_at IS NULL
    SQL
  end

  def down
    remove_column :subscriptions, :next_renewal_at
  end
end
