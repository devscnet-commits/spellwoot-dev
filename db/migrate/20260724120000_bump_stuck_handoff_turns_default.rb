# Gap 4: transfer_rules['stuck_handoff_turns'] passou a ser o TETO ABSOLUTO de turnos por etapa (o campo
# da tela "travar por X mensagens"), não mais o contador de tentativas frustradas. 3 era sensato como
# frustradas, agressivo como absoluto (3 perguntas transferia). Sobe o default-era 3 -> 10.
#
# SÓ o valor 3 (o default antigo) é migrado; valores custom (que o usuário escolheu deliberadamente) ficam
# como estão. Ninguém está em produção -> baixo risco. Reversível.
class BumpStuckHandoffTurnsDefault < ActiveRecord::Migration[7.1]
  def up
    execute(<<~SQL.squish)
      UPDATE ai_departments
      SET transfer_rules = jsonb_set(transfer_rules, '{stuck_handoff_turns}', '10'::jsonb)
      WHERE (transfer_rules->>'stuck_handoff_turns') = '3'
    SQL
  end

  def down
    execute(<<~SQL.squish)
      UPDATE ai_departments
      SET transfer_rules = jsonb_set(transfer_rules, '{stuck_handoff_turns}', '3'::jsonb)
      WHERE (transfer_rules->>'stuck_handoff_turns') = '10'
    SQL
  end
end
