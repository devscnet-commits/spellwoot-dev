require 'rails_helper'

# CONTRATO (item 1, conv 436): o Ai::StateManager depende de methods de módulo de Ai::StepSlot. Se um sumir num
# merge/deploy — foi o que aconteceu com domain_from_tool no worker: as CHAMADAS subiram no state_manager, a
# IMPLEMENTAÇÃO não — o rescue do tool_domain engole o NoMethodError e o domínio dinâmico é ignorado em SILÊNCIO.
# Este teste quebra no CI ANTES do deploy, não em prod uma hora depois. É DISTINTO do merge_recover spec, que
# cobre a SINTAXE do state_manager (o arquivo parseia); ele NÃO verifica a existência destes methods em OUTRA
# classe. Por isso o merge_recover não teria pego este bug — é o buraco que este spec fecha.
RSpec.describe Ai::StepSlot do
  describe 'contrato de módulo exigido pelo Ai::StateManager (grep Ai::StepSlot.<m> no state_manager)' do
    # A LISTA REAL, extraída das chamadas em app/services/ai/state_manager.rb. domain_from_tool é a mais crítica
    # (o gate de domínio dinâmico); as outras degradariam a captura/avanço em silêncio pelo mesmo caminho.
    %i[absent? attribute domain_from_tool optional? options type].each do |method_name|
      it "responde a .#{method_name} (some -> gate quebra em silêncio)" do
        expect(described_class).to respond_to(method_name)
      end
    end
  end
end
