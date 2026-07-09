require 'rails_helper'

# Unit coverage for the GENERIC polymorphic version model. It must NOT affect Ai::AgentVersion /
# Ai::PlaybookVersion (those keep their own tables/specs). Focus: flat-path snapshot, dedupe, and
# restore that deep-merges into jsonb columns without dropping sibling keys.
RSpec.describe Ai::Version do
  let(:account) { create(:account) }
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active') }
  let(:department) do
    Ai::Department.create!(
      account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active',
      behavior: {
        'auto_attendance' => true, 'reply_scope' => 'all',
        'grouping' => { 'delay_seconds' => 10 }, 'max_replies' => 3,
        'max_input_chars' => 500, 'max_input_action' => 'truncate',
        'max_input_message' => '', 'disabled_custom_attributes' => ['cpf']
      }
    )
  end
  let(:fields) { Api::V1::Accounts::AiDepartmentsController::DEPARTMENT_BEHAVIOR_FIELDS }

  describe '.snapshot!' do
    it 'creates v1 with a FLAT snapshot keyed by the dotted paths' do
      version = described_class.snapshot!(department, snapshot_fields: fields)

      expect(version.version_number).to eq(1)
      expect(version.versionable).to eq(department)
      expect(version.versionable_type).to eq('Ai::Department')
      expect(version.snapshot).to eq(
        'behavior.auto_attendance' => true,
        'behavior.reply_scope' => 'all',
        'behavior.grouping.delay_seconds' => 10,
        'behavior.max_replies' => 3,
        'behavior.max_input_chars' => 500,
        'behavior.max_input_action' => 'truncate',
        'behavior.max_input_message' => '',
        'behavior.disabled_custom_attributes' => ['cpf']
      )
    end

    it 'increments version_number scoped by versionable' do
      described_class.snapshot!(department, snapshot_fields: fields)
      department.update!(behavior: department.behavior.merge('max_replies' => 5))

      expect(described_class.snapshot!(department, snapshot_fields: fields).version_number).to eq(2)
    end

    it 'dedupes: no new version when the snapshot is identical and there is no note' do
      first = described_class.snapshot!(department, snapshot_fields: fields)
      again = described_class.snapshot!(department, snapshot_fields: fields)

      expect(again.id).to eq(first.id)
      expect(described_class.for_record(department).count).to eq(1)
    end

    it 'still records an identical snapshot when a note is given (rollback marker)' do
      described_class.snapshot!(department, snapshot_fields: fields)
      noted = described_class.snapshot!(department, snapshot_fields: fields, note: 'Restaurado da v1')

      expect(noted.version_number).to eq(2)
      expect(noted.note).to eq('Restaurado da v1')
    end

    it 'does not leak into Ai::AgentVersion / Ai::PlaybookVersion' do
      expect { described_class.snapshot!(department, snapshot_fields: fields) }
        .to not_change(Ai::AgentVersion, :count)
        .and not_change(Ai::PlaybookVersion, :count)
    end
  end

  describe '#restore!' do
    it 'reverts the versioned behavior keys, DEEP-MERGING so sibling keys are preserved' do
      v1 = described_class.snapshot!(department, snapshot_fields: fields)
      department.update!(behavior: department.behavior.merge(
        'max_replies' => 9, 'reply_scope' => 'assigned',
        'grouping' => { 'delay_seconds' => 99, 'foo' => 'bar' }, # foo is outside the scope
        'unrelated_key' => 'keep-me'
      ))

      v1.restore!(fields)
      department.reload

      # versioned keys are rolled back to v1
      expect(department.behavior['max_replies']).to eq(3)
      expect(department.behavior['reply_scope']).to eq('all')
      expect(department.behavior['auto_attendance']).to be(true)
      expect(department.behavior.dig('grouping', 'delay_seconds')).to eq(10)
      # keys/sub-keys OUTSIDE the versioned scope survive the merge
      expect(department.behavior['unrelated_key']).to eq('keep-me')
      expect(department.behavior.dig('grouping', 'foo')).to eq('bar')
    end
  end
end
