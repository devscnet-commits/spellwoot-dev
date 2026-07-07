# Snapshot DIÁRIO do excedente de um limite em paid_overage (billing Fase 2 — cobrança por média).
# Billing::OverageSnapshotJob grava 1 linha/dia por (conta, chave de limite). No fim do ciclo, a
# Ai::CreditsRenewalJob tira a média desses snapshots para gerar a OverageCharge.
class CreateOverageSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :overage_snapshots do |t|
      t.references :account, null: false, foreign_key: true
      t.string  :plan_limit_key, null: false
      t.integer :excess_count, null: false, default: 0
      t.date    :snapshot_date, null: false
      t.timestamps
    end
    # Idempotência do snapshot diário: 1 por (conta, chave, dia).
    add_index :overage_snapshots, %i[account_id plan_limit_key snapshot_date],
              unique: true, name: 'index_overage_snapshots_unique_daily'
  end
end
