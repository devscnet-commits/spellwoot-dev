# frozen_string_literal: true

# Frente C / PR1 — id ESTÁVEL (uuid) por etapa do playbook, para o merge-por-id (upsert) e, depois, o
# ai_step_id (PR2). Backfill de DADOS (nenhuma mudança de schema): injeta 'id' em cada step de TODOS os
# playbook.steps E nos steps de cada snapshot de Ai::Version(Ai::Playbook) — senão o restore futuro perde a
# identidade.
#
# IDEMPOTENTE: só atribui id a step que NÃO tem ('id' em branco). Rodar duas vezes NÃO gera id novo por cima
# dos existentes. Usa update_column (pula validações/callbacks — inclusive a validação H6 do on_complete, que
# não deve barrar um backfill de id). NÃO converte ai_step_index (isso é o PR2).
#
# RODA EM PRODUÇÃO, não no sandbox (0 playbooks, 0 versões aqui). Dimensione a janela ANTES do deploy:
#   Ai::Playbook.count
#   Ai::Version.where(versionable_type: "Ai::Playbook").count
#   Ai::Version.where(versionable_type: "Ai::Playbook").sum { |v| (v.snapshot["steps"] || []).size }
class BackfillAiStepIds < ActiveRecord::Migration[7.1]
  def up
    # update_column de propósito: backfill de DADOS, sem disparar validações/callbacks (nem a validação H6
    # do on_complete, que não deve barrar um backfill de id).
    ::Ai::Playbook.find_each do |playbook|
      steps, changed = steps_with_ids(playbook.steps)
      playbook.update_column(:steps, steps) if changed # rubocop:disable Rails/SkipsModelValidations
    end

    ::Ai::Version.where(versionable_type: 'Ai::Playbook').find_each do |version|
      snapshot = version.snapshot || {}
      steps, changed = steps_with_ids(snapshot['steps'])
      next unless changed

      snapshot['steps'] = steps
      version.update_column(:snapshot, snapshot) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Devolve [steps_com_id, mudou?]. Só toca step (Hash) SEM 'id'. Idempotente.
  def steps_with_ids(steps)
    return [steps, false] unless steps.is_a?(Array)

    changed = false
    new_steps = steps.map do |step|
      next step unless step.is_a?(Hash)
      next step if step['id'].present?

      changed = true
      step.merge('id' => SecureRandom.uuid)
    end
    [new_steps, changed]
  end
end
