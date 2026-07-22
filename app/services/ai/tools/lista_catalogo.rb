# Ferramenta NATIVA de LEITURA (Fix 3b): devolve TODO o catálogo (chunks kind 'produto') da conta/
# department, reusando o "catálogo pequeno" do Ai::KnowledgeRetriever (acima do limite cai na vetorial
# restrita ao kind). SOMENTE leitura — nenhum efeito colateral. Instanciada com o contexto do turno e
# anexada via chat.with_tools SÓ ao vivo (em shadow nunca é anexada). O provider controla o loop
# (pede a tool -> a gem chama #execute -> realimenta o resultado).
class Ai::Tools::ListaCatalogo < RubyLLM::Tool
  description 'Retorna a LISTA COMPLETA de planos/produtos do catálogo da empresa (nomes, valores, ' \
              'características). Use quando o cliente pedir os planos, o catálogo ou os preços.'

  # Nome estável e limpo exposto ao modelo (sobrescreve a derivação do class name com "::").
  def name
    'lista_catalogo'
  end

  # on_read: callback de AUDITORIA (o Gateway registra Ai::CapabilityExecution + evento tool.native_read).
  def initialize(account_id:, department_id:, on_read: nil)
    super()
    @account_id = account_id
    @department_id = department_id
    @on_read = on_read
  end

  def execute
    chunks = Ai::KnowledgeRetriever.retrieve(query: 'catálogo completo de planos e produtos',
                                             account_id: @account_id, department_id: @department_id, kinds: ['produto'])
    @on_read&.call('lista_catalogo', { 'kind' => 'produto' }, chunks)
    return 'Nenhum produto cadastrado no catálogo.' if chunks.empty?

    "Catálogo completo (use APENAS estes itens; não invente):\n#{chunks.join("\n---\n")}"
  rescue StandardError => e
    Rails.logger.error "[Ai::Tools::ListaCatalogo] #{e.class}: #{e.message}"
    'Não foi possível consultar o catálogo agora.'
  end
end
