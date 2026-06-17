# frozen_string_literal: true

# Copies the full business-hours configuration (weekly schedule, holidays,
# exceptions, timezone and auto-messages) from a source inbox to other inboxes
# in the same account, based on a replication scope.
class Inboxes::BusinessHoursReplicationService
  SHARED_ATTRS = %w[working_hours_enabled timezone out_of_office_message interval_message holiday_message].freeze

  def initialize(source:, scope:, inbox_ids: [])
    @source    = source
    @account   = source.account
    @scope     = scope.to_s
    @inbox_ids = Array(inbox_ids).map(&:to_i)
  end

  # Replication is best-effort per inbox: one inbox that rejects the copy (e.g. an
  # incompatible channel) must not abort the whole batch — the others still get the
  # config, and the failures are reported back so they surface in the UI instead of a
  # blanket 422. Each copy_to runs in its own transaction, so a failure rolls back only
  # that inbox.
  def perform
    succeeded = 0
    failed = []
    target_inboxes.find_each do |inbox|
      copy_to(inbox)
      succeeded += 1
    rescue StandardError => e
      Rails.logger.error "[BusinessHoursReplication] target_inbox_id=#{inbox.id} #{e.class}: #{e.message}"
      failed << { id: inbox.id, name: inbox.name, error: e.message }
    end
    { ok: failed.empty?, count: succeeded, failed: failed }
  end

  private

  def target_inboxes
    base = @account.inboxes.where.not(id: @source.id)
    case @scope
    when 'account'  then base
    when 'selected' then base.where(id: @inbox_ids)
    when 'team'     then base.joins(:team_inboxes).where(team_inboxes: { team_id: @source.team_ids }).distinct
    else Inbox.none
    end
  end

  def copy_to(inbox)
    ActiveRecord::Base.transaction do
      inbox.update!(@source.slice(*SHARED_ATTRS))
      copy_working_periods(inbox)
      copy_holidays(inbox)
      copy_exceptions(inbox)
    end
  end

  def copy_working_periods(inbox)
    inbox.working_periods.delete_all
    @source.working_periods.find_each do |period|
      inbox.working_periods.create!(period.slice(*Inbox::PERIOD_ATTRS).merge('inbox_id' => inbox.id))
    end
  end

  def copy_holidays(inbox)
    inbox.inbox_holidays.delete_all
    @source.inbox_holidays.find_each do |holiday|
      inbox.inbox_holidays.create!(holiday.slice(*Inbox::HOLIDAY_ATTRS).merge('inbox_id' => inbox.id))
    end
  end

  def copy_exceptions(inbox)
    inbox.inbox_exceptions.delete_all
    @source.inbox_exceptions.find_each do |exception|
      inbox.inbox_exceptions.create!(exception.slice('name', 'exception_date', 'closed', 'periods').merge('inbox_id' => inbox.id))
    end
  end
end
