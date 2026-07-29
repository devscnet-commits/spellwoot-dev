require 'rails_helper'

RSpec.describe Ai::StepResolver do
  # O caminho do quarto bucket (on_complete, etapa SEM slot) não toca o slot_collector nem a conversa —
  # um double basta. As outras redes (slot/recusa/teto) já são cobertas por integração no gateway_spec.
  subject(:resolver) { described_class.new(conversation: double('conversation')) }

  # (b)-core — QUARTO bucket: etapa SEM slot que declara on_complete conclui de forma DETERMINÍSTICA,
  # NUNCA por decision['step_completed']. conclude_ready vem do StateManager (obrigatórios ≤ índice).
  describe '#resolve_completion — desfecho declarado (on_complete)' do
    let(:on_complete) { { 'action' => 'handoff_human', 'team_id' => 7, 'reason' => 'conclusao' } }
    let(:step) { { 'name' => 'Finalização', 'on_complete' => on_complete } }

    # decision SEM step_completed: o desfecho não depende do modelo — é o código que decide.
    def resolve(decision, conclude_ready:)
      resolver.resolve_completion(step, decision, 10, 5, nil, false, conclude_ready: conclude_ready)
    end

    it 'conclude_ready:true -> emite signal {conclude: on_complete} mesmo SEM step_completed do modelo' do
      out = resolve({ 'decision' => 'reply' }, conclude_ready: true)

      expect(out[:signal]).to eq(conclude: on_complete)
      expect(out[:completed]).to be(false)
    end

    it 'conclude_ready:false -> conclude_blocked, NENHUM signal e não avança' do
      out = resolve({ 'decision' => 'reply' }, conclude_ready: false)

      expect(out[:conclude_blocked]).to be(true)
      expect(out[:signal]).to be_nil
      expect(out[:completed]).to be(false)
    end

    # Prova de MUTAÇÃO por nome: step_completed:true NÃO força a conclusão quando não está pronto (é
    # determinístico), e é IRRELEVANTE quando está pronto (nunca é consultado no quarto bucket).
    it 'ignora step_completed do modelo: true não conclui se não-pronto, e não é lido se pronto' do
      blocked = resolve({ 'step_completed' => true }, conclude_ready: false)
      ready   = resolve({ 'step_completed' => true }, conclude_ready: true)

      expect(blocked[:signal]).to be_nil          # bloqueado APESAR de step_completed:true
      expect(ready[:signal]).to eq(conclude: on_complete)
    end

    it 'action fora do contrato (handoff_human|close|handoff_ai) -> etapa comum: segue step_completed' do
      on_complete['action'] = 'garbage'
      out = resolve({ 'decision' => 'reply', 'step_completed' => true }, conclude_ready: true)

      expect(out[:signal]).to be_nil
      expect(out[:completed]).to be(true) # caiu no bucket antigo (sinal do modelo)
    end

    it 'close e handoff_ai também emitem o signal quando pronto' do
      %w[close handoff_ai].each do |action|
        on_complete['action'] = action
        out = resolve({ 'decision' => 'reply' }, conclude_ready: true)
        expect(out[:signal]).to eq(conclude: on_complete)
      end
    end
  end
end
