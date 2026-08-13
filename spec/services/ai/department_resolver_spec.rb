require 'rails_helper'

RSpec.describe Ai::DepartmentResolver do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end
  let!(:dept_a) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Suporte', status: 'active',
                           is_default: true, behavior: {})
  end
  let!(:dept_b) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Vendas', status: 'active', behavior: {})
  end

  def resolve
    described_class.resolve(agent: agent, inbox_id: inbox.id, message_content: 'oi', conversation: conversation)
  end

  def set_override(id)
    conversation.update!(additional_attributes: { 'ai_department_override' => id })
  end

  describe 'override (passo 0)' do
    it 'honors a valid active override, winning over the classifier' do
      set_override(dept_b.id)

      dept, method = resolve

      expect(method).to eq('override')
      expect(dept).to eq(dept_b)
    end

    it 'ignores an override to an INACTIVE department (falls through, no override)' do
      dept_b.update!(status: 'inactive')
      set_override(dept_b.id)
      allow(described_class).to receive(:classify).and_return(nil)

      dept, method = resolve

      expect(method).not_to eq('override')
      expect(dept).not_to eq(dept_b)
    end

    it 'ignores an override to a department of ANOTHER agent/account (multi-tenant isolation)' do
      other_account = create(:account)
      other_profile = Ai::OperationProfile.create!(account_id: other_account.id, name: 'b',
                                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
      other_agent = Ai::Agent.create!(account: other_account, name: 'X', status: 'active',
                                      ai_operation_profile_id: other_profile.id)
      foreign = Ai::Department.create!(account: other_account, ai_agent_id: other_agent.id, name: 'Y',
                                       status: 'active', behavior: {})
      set_override(foreign.id)
      allow(described_class).to receive(:classify).and_return(nil)

      dept, method = resolve

      expect(method).not_to eq('override')
      expect([dept_a, dept_b]).to include(dept)
    end

    it 'ignores a deleted/unknown override id (falls through)' do
      set_override(999_999)
      allow(described_class).to receive(:classify).and_return(nil)

      _dept, method = resolve

      expect(method).not_to eq('override')
    end

    it 'resolves normally when there is no override' do
      allow(described_class).to receive(:classify).and_return(nil)

      _dept, method = resolve

      expect(method).not_to eq('override')
    end
  end

  # Bug real ao vivo: Ai::FollowupConversationJob chama .resolve com message_content: nil (não há
  # mensagem nova no contexto de follow-up). O comentário do job já dizia "classifier pulado", mas o
  # código NÃO pulava de verdade pra agente multi-department sem mapeamento único — chamava o LLM pra
  # classificar uma mensagem VAZIA, resultado não-determinístico, follow-up caindo num department sem
  # nada configurado. Sem override/mapeamento único, dept_a/dept_b (o fixture do describe) caem
  # exatamente nesse caso: SÓ o classifier decidiria entre os dois.
  describe 'classificador SKIP quando message_content está em branco (bug real: follow-up com mensagem nil)' do
    def resolve_with(content)
      described_class.resolve(agent: agent, inbox_id: inbox.id, message_content: content, conversation: conversation)
    end

    it 'message_content nil: NÃO chama .classify, cai direto no default determinístico' do
      expect(described_class).not_to receive(:classify)

      dept, method = resolve_with(nil)

      expect(method).to eq('default')
      expect(dept).to eq(dept_a) # is_default: true no fixture
    end

    it 'message_content "" (string vazia): mesmo skip' do
      expect(described_class).not_to receive(:classify)

      _dept, method = resolve_with('')

      expect(method).to eq('default')
    end

    it 'message_content "   " (só espaço, .presence trata como blank): mesmo skip' do
      expect(described_class).not_to receive(:classify)

      _dept, method = resolve_with('   ')

      expect(method).to eq('default')
    end

    it 'message_content presente: continua chamando .classify normalmente (não regride o caminho real)' do
      expect(described_class).to receive(:classify).and_return(dept_b)

      dept, method = resolve_with('quero saber sobre vendas')

      expect(method).to eq('classifier')
      expect(dept).to eq(dept_b)
    end
  end
end
