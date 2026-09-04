class AutoAssignment::PeriodicAssignmentJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Account.find_in_batches do |accounts|
      accounts.each do |account|
        next unless account.feature_enabled?('assignment_v2')

        # Every inbox with auto-assignment on, not only the ones linked to an assignment
        # policy. joins(:assignment_policy) is an inner join, so inboxes running on the
        # default policy values had no periodic retry at all: if the real-time attempt on
        # status change found no available agent, the conversation stayed unassigned forever.
        account.inboxes.where(enable_auto_assignment: true).find_in_batches do |inboxes|
          inboxes.each do |inbox|
            next unless inbox.auto_assignment_v2_enabled?

            AutoAssignment::AssignmentJob.perform_later(inbox_id: inbox.id)
          end
        end
      end
    end
  end
end
