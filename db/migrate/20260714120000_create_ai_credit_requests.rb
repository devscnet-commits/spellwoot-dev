# Solicitação de MAIS créditos de IA feita pelo cliente (plano básico) ao querer aumentar o teto.
# Vira uma fila de aprovação manual da SCNET (super_admin): status pending -> approved (credita
# extra_credits do AiCreditBalance) | rejected. Billing FASE 1 — só o fluxo de solicitação/aprovação;
# o enforcement de bloqueio por crédito é Fase 2 (fora de escopo).
class CreateAiCreditRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_credit_requests do |t|
      t.references :account, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, null: true, foreign_key: { to_table: :users }
      t.integer  :amount_requested, null: false
      t.integer  :status, null: false, default: 0 # pending:0 approved:1 rejected:2
      t.text     :reason       # texto do cliente explicando por que precisa
      t.text     :review_note  # nota da SCNET ao aprovar/rejeitar
      t.datetime :reviewed_at
      t.timestamps
    end
  end
end
