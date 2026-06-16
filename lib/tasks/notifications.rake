# frozen_string_literal: true

namespace :notifications do
  # One-off backfill: turn OFF the email notifications that were flooding inboxes
  # (conversation assignment + new messages on assigned/participating conversations)
  # for every existing user. Leaves other email flags (mention, SLA, creation) and all
  # push/in-app notifications untouched. Account emails (password reset/confirmation)
  # are Devise mailers and are not affected by notification settings.
  #
  # Usage: bundle exec rails notifications:disable_message_emails
  desc 'Disable assignment + new-message email notifications for all existing users'
  task disable_message_emails: :environment do
    flags_to_disable = %i[
      email_conversation_assignment
      email_assigned_conversation_new_message
      email_participating_conversation_new_message
    ]

    updated = 0
    NotificationSetting.find_each do |setting|
      current = setting.selected_email_flags
      remaining = current - flags_to_disable
      next if remaining == current

      setting.selected_email_flags = remaining
      setting.save!
      updated += 1
    end

    puts "notifications:disable_message_emails — updated #{updated} notification setting(s)"
  end
end
