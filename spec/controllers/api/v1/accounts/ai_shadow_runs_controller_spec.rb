require 'rails_helper'

# Cobertura direta de #classify/#row (métodos privados puros — tomam o `run` como argumento, não
# dependem de params/request, mesmo padrão de spec/jobs/ai/followup_conversation_job_spec.rb pra
# testar sem precisar montar toda a stack de autenticação HTTP). Achado ao vivo (18/08): esta tela
# nunca teve NENHUMA cobertura — foi exatamente por isso que a incompatibilidade de chaves em
# decision (Ai::Gateway escrevia 'kind'/'text', esta tela lê 'decision'/'reply_text') passou
# despercebida: 100% dos runs reais do motor Python caíam em 'unanswered' sem nenhum teste flagrar.
RSpec.describe Api::V1::Accounts::AiShadowRunsController do
  let(:account) { create(:account) }
  let(:controller_instance) { described_class.new }

  def run_with_decision(decision, status: 'recorded', error_type: nil, knowledge_count: 0)
    Ai::Run.create!(account_id: account.id, decision: decision, status: status, error_type: error_type,
                    knowledge_count: knowledge_count)
  end

  describe '#classify — contrato ATUAL do Python (decision/reply_text/confidence)' do
    it 'reply respondido + sem conhecimento usado -> instruction' do
      run = run_with_decision({ 'decision' => 'reply', 'reply_text' => 'Claro, posso ajudar!' })

      expect(controller_instance.send(:classify, run)).to eq('instruction')
    end

    it 'reply respondido + conhecimento usado -> knowledge' do
      run = run_with_decision({ 'decision' => 'reply', 'reply_text' => 'Segundo nossa base...' },
                              knowledge_count: 2)

      expect(controller_instance.send(:classify, run)).to eq('knowledge')
    end

    it 'handoff (o próprio modelo transferiu) -> transfer, NÃO unanswered' do
      run = run_with_decision({ 'decision' => 'handoff', 'reply_text' => 'Vou te transferir!' })

      expect(controller_instance.send(:classify, run)).to eq('transfer')
    end

    it 'erro de provider -> error, antes de olhar decision' do
      run = run_with_decision({ 'decision' => 'reply', 'reply_text' => 'x' }, status: 'error',
                              error_type: 'provider_error')

      expect(controller_instance.send(:classify, run)).to eq('error')
    end

    # Achado ao vivo: o BUG (Gateway escrevendo 'kind'/'text' em vez de 'decision'/'reply_text') fazia
    # TODO turno real cair aqui — prova que a correção realmente resolve o sintoma relatado.
    it 'formato ANTIGO ("kind"/"text", o bug pré-correção) cai em unanswered' do
      run = run_with_decision({ 'kind' => 'reply', 'text' => 'Respondeu de verdade' })

      expect(controller_instance.send(:classify, run)).to eq('unanswered')
    end
  end

  describe '#row — "ferramenta ausente" NUNCA aponta um nome de controle reservado' do
    def missing_flag_for(tool_name)
      run = run_with_decision({ 'decision' => 'tool', 'tool' => { 'name' => tool_name } })
      controller_instance.send(:row, run, {}, {}, {}, {})[:tool_missing]
    end

    it 'salvar_memoria_ia e continuar_conversa NUNCA são "ferramenta ausente" (nomes de controle, não configuráveis)' do
      expect(missing_flag_for('salvar_memoria_ia')).to be(false)
      expect(missing_flag_for('continuar_conversa')).to be(false)
      expect(missing_flag_for('avancar_etapa')).to be(false)
      expect(missing_flag_for('conversation.resolve')).to be(false)
      expect(missing_flag_for('conversation.transfer')).to be(false)
    end

    it 'uma ferramenta REAL não cadastrada no department CONTINUA sendo apontada como ausente' do
      expect(missing_flag_for('Consultar_Viabilidade')).to be(true)
    end
  end
end
