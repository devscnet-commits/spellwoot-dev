# Polymorphic, immutable snapshot of a versionable record's configuration — the single versioning
# substrate for agents and playbooks. Instead of a fixed SNAPSHOT_FIELDS + a dedicated table per
# scope, the caller passes `snapshot_fields` and the `versionable` association points at any record
# (Ai::Agent, Ai::Playbook). Old rows with versionable_type 'Ai::Department' (pre-19/08 fusão
# Departamento -> Agente) are historical-only now — that class no longer exists, so #versionable on
# those raises; harmless (nothing reads them), just can't be restored.
#
# `snapshot_fields` may be plain column names ("objetivo") OR dotted paths into a jsonb column
# ("behavior.max_replies", "behavior.grouping.delay_seconds"). The stored snapshot is a FLAT map
# keyed by those paths; restore re-applies them, DEEP-MERGING into jsonb columns so sibling keys
# that are not part of the scope (e.g. other behavior keys) are never dropped.
# == Schema Information
#
# Table name: ai_versions
#
#  id               :bigint           not null, primary key
#  note             :string
#  snapshot         :jsonb            not null
#  version_number   :integer          default(1), not null
#  versionable_type :string           not null
#  versionable_id   :bigint           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#
# Indexes
#
#  index_ai_versions_on_versionable_type_and_versionable_id  (versionable_type,versionable_id)
#
class Ai::Version < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :versionable, polymorphic: true

  scope :recent, -> { order(version_number: :desc) }
  scope :for_record, ->(record) { where(versionable: record) }

  # Records a new version unless the snapshot is identical to the latest one and there is no note
  # (avoids noise on no-op saves).
  def self.snapshot!(record, snapshot_fields:, note: nil)
    data = read_paths(record, snapshot_fields)
    last = for_record(record).recent.first
    return last if last && last.snapshot == data && note.nil?

    create!(account_id: record.account_id, versionable: record, note: note,
            version_number: last ? last.version_number + 1 : 1, snapshot: data)
  end

  # Re-applies the snapshotted fields onto the versionable record.
  #
  # A field given as a DOTTED path ("behavior.max_replies") targets a sub-key of a jsonb column and is
  # DEEP-MERGED into the current column so sibling keys outside the scope are preserved (agent
  # versioning relies on this). A field given as a PLAIN column name ("default_messages", "steps")
  # SUBSTITUTES the whole column value — even when that value is itself a Hash/Array — matching the
  # old slice+update! behavior of Ai::AgentVersion/Ai::PlaybookVersion (restoring a playbook's steps
  # or default_messages replaces the list/map, never mixes stale entries in).
  def restore!(snapshot_fields)
    patches = {}          # column name (String) => value to assign (scalar/Array/Hash)
    merge_columns = Set.new # columns fed by a dotted path -> deep-merge into current; others substitute
    snapshot_fields.each do |path|
      next unless snapshot.key?(path)

      segments = path.split('.')
      column = segments.first
      if segments.length == 1
        patches[column] = snapshot[path]
      else
        merge_columns << column
        nested = segments[1..].reverse.reduce(snapshot[path]) { |acc, key| { key => acc } }
        patches[column] = (patches[column] || {}).deep_merge(nested)
      end
    end

    assignments = patches.to_h do |column, patch|
      if merge_columns.include?(column)
        current = versionable.public_send(column)
        value = current.is_a?(Hash) ? current.deep_merge(patch) : patch
        [column, value]
      else
        [column, patch] # plain column: substitui o valor inteiro (sem merge)
      end
    end
    versionable.update!(assignments)
  end

  # Reads each field/path off the record into a flat { path => value } hash.
  def self.read_paths(record, fields)
    fields.index_with { |path| dig_path(record, path) }
  end

  def self.dig_path(record, path)
    segments = path.split('.')
    root = record.public_send(segments.first)
    return root if segments.length == 1

    root.is_a?(Hash) ? root.dig(*segments[1..]) : nil
  end
  private_class_method :read_paths, :dig_path
end
