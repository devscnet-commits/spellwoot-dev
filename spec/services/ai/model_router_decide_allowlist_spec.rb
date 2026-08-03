require 'rails_helper'

# GUARDA DE ARQUITETURA (frente de processo, não só "quatro bugs").
#
# O commit 3cc275025 fez Ai::ModelRouter.decide anexar o DecisionSchema STRICT. Desde então, TODO chamador
# que esperava TEXTO LIVRE (um JSON próprio no system_prompt) passou a receber o ENVELOPE de decisão
# (decision/asked_slot/attributes/confidence/reply_text) — EM SILÊNCIO: status "recorded", sem erro, custando
# dinheiro e produzindo lixo. Foram QUATRO (handoff_summary, prompt_assistant, customer_memory, copilot), e o
# que faltou foi um spec do FORMATO da saída — o decide não avisa quando o consumidor não é do tipo dele.
#
# Esta guarda lista os chamadores de `Ai::ModelRouter.decide(` numa ALLOWLIST EXPLÍCITA e falha se um NOVO
# aparecer. Mudar de novo o comportamento do decide (ou plugar um novo consumidor) OBRIGA a revisão:
#   - :legitimo = quer o ENVELOPE de decisão de propósito (a decisão do supervisor).
#   - :pendente = bug da família (espera texto livre) a MIGRAR para call_model — remova daqui ao migrar.
# Regra: quem quer JSON livre usa Ai::ModelRouter.call_model (sem schema) + parse; só a DECISÃO usa decide.
RSpec.describe 'Ai::ModelRouter.decide — allowlist de consumidores (guarda de arquitetura)' do # rubocop:disable RSpec/DescribeClass
  # Todo chamador PRECISA estar aqui, com o motivo. (let, não constante — evita vazamento de constante no bloco.)
  let(:allowed) do
    {
      'app/services/ai/gateway.rb' => :legitimo,          # a DECISÃO do supervisor (reply/handoff/close/tool)
      'app/services/ai/shadow_evaluator.rb' => :legitimo, # registra a decisão que TERIA sido tomada (shadow)
      'app/services/ai/tester.rb' => :legitimo,           # simula a decisão do agente no testador
      # BUG conhecido da família: copilot pede {suggested_reply,summary,next_steps} mas recebe o envelope.
      # Migrar para call_model + parse e REMOVER esta linha (ver memória decide-strict-envelope-family).
      'app/services/ai/copilot.rb' => :pendente
    }
  end

  # 'ModelRouter.decide(' com parêntese exclui o COMENTÁRIO histórico ("usava ModelRouter.decide" no
  # handoff_summary) e a própria definição `def self.decide`. Caminho relativo normalizado para '/'.
  def decide_callers
    Dir.glob(Rails.root.join('app/**/*.rb'))
       .select { |p| File.read(p).include?('ModelRouter.decide(') }
       .map { |p| Pathname.new(p).relative_path_from(Rails.root).to_s.tr('\\', '/') }
  end

  it 'todo chamador de decide está na allowlist — um NOVO chamador quebra este teste (força revisão)' do
    expect(decide_callers).to match_array(allowed.keys)
  end

  it 'o débito PENDENTE (bug da família ainda não migrado) está explícito' do
    # Quando o copilot migrar para call_model, ele sai de decide_callers E daqui — os dois têm de bater.
    expect(allowed.select { |_f, kind| kind == :pendente }.keys).to eq(['app/services/ai/copilot.rb'])
  end
end
