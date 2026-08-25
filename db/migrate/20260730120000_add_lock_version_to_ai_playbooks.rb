# (1) Guardrail contra sobrescrita CEGA do array de steps (frente on_complete/Frente C). O painel manda o
# playbook.steps INTEIRO no save; se o array do cliente estiver defasado (ex.: on_complete/knowledge/list_all
# escritos por console DEPOIS do load), o save reescreve por cima e apaga em silêncio. lock_version é o token
# de concorrência otimista do Rails: incrementa em TODO UPDATE do playbook — inclusive os por console (que
# NÃO geram Ai::Version) — então o controller detecta o cliente defasado e responde 409 em vez de sobrescrever.
class AddLockVersionToAiPlaybooks < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_playbooks, :lock_version, :integer, null: false, default: 0
  end
end
