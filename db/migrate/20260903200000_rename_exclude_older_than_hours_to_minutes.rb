class RenameExcludeOlderThanHoursToMinutes < ActiveRecord::Migration[7.1]
  # Self-contained AR class so the backfill is decoupled from future app-model changes.
  class MigrationPolicy < ApplicationRecord
    self.table_name = 'agent_capacity_policies'
  end

  # The frontend's duration input always stores this value in minutes, but the backend was
  # reading it as hours (a 60x bug). The stored number itself was always minutes as entered
  # by the admin, so this only renames the key — no numeric conversion needed.
  def up
    rename_key('exclude_older_than_hours', 'exclude_older_than_minutes')
  end

  def down
    rename_key('exclude_older_than_minutes', 'exclude_older_than_hours')
  end

  private

  def rename_key(from_key, to_key)
    MigrationPolicy.find_each do |policy|
      rules = policy.exclusion_rules || {}
      next unless rules.key?(from_key)

      rules[to_key] = rules.delete(from_key)
      policy.update_column(:exclusion_rules, rules)
    end
  end
end
