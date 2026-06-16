namespace :result do
  # Backfills one initial history event per conversation that already carries a business
  # result (won/lost) in the legacy additional_attributes.outcome. Safe to re-run: it skips
  # conversations that already have a result event. Run on demand after deploy.
  desc 'Backfill conversation_result_events from existing outcomes'
  task backfill_events: :environment do
    scope = Conversation.where(result: %i[won lost])
                        .where.not(id: ConversationResultEvent.select(:conversation_id))

    total = 0
    scope.find_in_batches(batch_size: 1000) do |batch|
      rows = batch.map do |conversation|
        {
          conversation_id: conversation.id,
          account_id: conversation.account_id,
          inbox_id: conversation.inbox_id,
          team_id: conversation.team_id,
          result: Conversation.results[conversation.result],
          previous_result: 0,
          event_type: 'backfill',
          created_at: conversation.result_set_at || conversation.updated_at,
          updated_at: Time.current
        }
      end

      ConversationResultEvent.insert_all(rows) if rows.any?
      total += rows.size
      puts "Backfilled #{total} result events..."
    end

    puts "Done. #{total} result events created."
  end

  # WARNING: DESTRUCTIVE FOR EXTERNAL INTEGRATIONS. Removes additional_attributes.outcome /
  # outcome_set_at. Only run AFTER every external consumer (n8n, CRM, webhooks) has migrated to
  # the native result / closed_by_ai fields. While dual-write is on, do NOT run this in production.
  desc 'Strip legacy additional_attributes.outcome (run only after integrations migrate)'
  task strip_legacy_outcome: :environment do
    total = 0
    Conversation.where("additional_attributes ? 'outcome' OR additional_attributes ? 'outcome_set_at'")
                .in_batches(of: 1000) do |batch|
      total += batch.update_all(
        "additional_attributes = additional_attributes - 'outcome' - 'outcome_set_at'"
      )
      puts "Stripped #{total} conversations..."
    end

    puts "Done. #{total} conversations cleaned."
  end
end
