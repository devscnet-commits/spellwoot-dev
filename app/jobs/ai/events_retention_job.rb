# Retention/PII minimization (LGPD): hard-deletes ai_events older than RETENTION_PERIOD.
#
# ai_events is an OPERATIONAL trail — the durable per-contact facts live in Ai::CustomerMemory, and
# the only long-term reader (the Análises/Shadow screen) caps its window at 1 year (MAX_WINDOW_DAYS),
# so nothing readable today is lost. Goal is reducing PII exposure, not storage/perf.
#
# RETENTION_PERIOD is the single knob — lower it (e.g. 90.days) if we tighten the policy later.
class Ai::EventsRetentionJob < ApplicationJob
  queue_as :low

  # ⬇️ Ajuste aqui se encurtar a retenção no futuro (ex.: 90.days). Casado hoje com o teto de 1 ano
  # da tela de Análises (AiShadowRunsController::MAX_WINDOW_DAYS = 365) — não perde consulta possível.
  RETENTION_PERIOD = 12.months

  # Batch size for deletes — keeps each statement short so we never hold a long lock on a growing table.
  DELETE_BATCH_SIZE = 5_000

  def perform
    cutoff = RETENTION_PERIOD.ago
    ::Ai::Event.where(created_at: ...cutoff)
               .in_batches(of: DELETE_BATCH_SIZE)
               .delete_all
  end
end
