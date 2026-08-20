require 'rails_helper'

# Unit coverage for the polymorphic version model — the single versioning substrate for agents and
# playbooks. Focus: flat-path snapshot, dedupe, restore that SUBSTITUTES plain columns and
# DEEP-MERGES dotted jsonb paths (preserving sibling keys).
RSpec.describe Ai::Version do
  let(:account) { create(:account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(
      account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id,
      behavior: {
        'auto_attendance' => true, 'reply_scope' => 'all',
        'grouping' => { 'delay_seconds' => 10 }, 'max_replies' => 3,
        'max_input_chars' => 500, 'max_input_action' => 'truncate',
        'max_input_message' => ''
      }
    )
  end
  let(:fields) { Api::V1::Accounts::AiAgentsController::BEHAVIOR_FIELDS }

  describe '.snapshot!' do
    it 'creates v1 with a FLAT snapshot keyed by the dotted paths' do
      version = described_class.snapshot!(agent, snapshot_fields: fields)

      expect(version.version_number).to eq(1)
      expect(version.versionable).to eq(agent)
      expect(version.versionable_type).to eq('Ai::Agent')
      expect(version.snapshot).to eq(
        'behavior.auto_attendance' => true,
        'behavior.reply_scope' => 'all',
        'behavior.grouping.delay_seconds' => 10,
        'behavior.max_replies' => 3,
        'behavior.max_input_chars' => 500,
        'behavior.max_input_action' => 'truncate',
        'behavior.max_input_message' => ''
      )
    end

    it 'increments version_number scoped by versionable' do
      described_class.snapshot!(agent, snapshot_fields: fields)
      agent.update!(behavior: agent.behavior.merge('max_replies' => 5))

      expect(described_class.snapshot!(agent, snapshot_fields: fields).version_number).to eq(2)
    end

    it 'dedupes: no new version when the snapshot is identical and there is no note' do
      first = described_class.snapshot!(agent, snapshot_fields: fields)
      again = described_class.snapshot!(agent, snapshot_fields: fields)

      expect(again.id).to eq(first.id)
      expect(described_class.for_record(agent).count).to eq(1)
    end

    it 'still records an identical snapshot when a note is given (rollback marker)' do
      described_class.snapshot!(agent, snapshot_fields: fields)
      noted = described_class.snapshot!(agent, snapshot_fields: fields, note: 'Restaurado da v1')

      expect(noted.version_number).to eq(2)
      expect(noted.note).to eq('Restaurado da v1')
    end
  end

  describe '#restore! (plain columns SUBSTITUEM, sem merge)' do
    let(:playbook) do
      Ai::Playbook.create!(agent: agent, objetivo: 'v1', active: true,
                           steps: [{ 'name' => 'a' }, { 'name' => 'b' }], transfer_when: [], close_when: [],
                           default_messages: { 'greeting' => 'oi', 'bye' => 'tchau' })
    end
    let(:pb_fields) { Ai::Playbook::SNAPSHOT_FIELDS }

    it 'substitui a lista inteira de steps (array), sem misturar itens antigos com novos' do
      v1 = described_class.snapshot!(playbook, snapshot_fields: pb_fields)
      playbook.update!(steps: [{ 'name' => 'x' }, { 'name' => 'y' }, { 'name' => 'z' }])

      v1.restore!(pb_fields)

      expect(playbook.reload.steps).to eq([{ 'name' => 'a' }, { 'name' => 'b' }])
    end

    it 'substitui default_messages (hash) inteiro, sem deep-merge das chaves atuais' do
      v1 = described_class.snapshot!(playbook, snapshot_fields: pb_fields)
      playbook.update!(default_messages: { 'greeting' => 'hello', 'extra' => 'novo' })

      v1.restore!(pb_fields)

      # a chave 'extra' (inexistente na v1) NÃO sobrevive; volta exatamente ao estado v1
      expect(playbook.reload.default_messages).to eq({ 'greeting' => 'oi', 'bye' => 'tchau' })
    end
  end

  describe '#restore! (dotted paths fazem DEEP-MERGE)' do
    it 'reverts the versioned behavior keys, DEEP-MERGING so sibling keys are preserved' do
      v1 = described_class.snapshot!(agent, snapshot_fields: fields)
      agent.update!(behavior: agent.behavior.merge(
        'max_replies' => 9, 'reply_scope' => 'assigned',
        'grouping' => { 'delay_seconds' => 99, 'foo' => 'bar' }, # foo is outside the scope
        'unrelated_key' => 'keep-me'
      ))

      v1.restore!(fields)
      agent.reload

      # versioned keys are rolled back to v1
      expect(agent.behavior['max_replies']).to eq(3)
      expect(agent.behavior['reply_scope']).to eq('all')
      expect(agent.behavior['auto_attendance']).to be(true)
      expect(agent.behavior.dig('grouping', 'delay_seconds')).to eq(10)
      # keys/sub-keys OUTSIDE the versioned scope survive the merge
      expect(agent.behavior['unrelated_key']).to eq('keep-me')
      expect(agent.behavior.dig('grouping', 'foo')).to eq('bar')
    end
  end
end
