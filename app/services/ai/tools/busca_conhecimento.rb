# Ferramenta NATIVA de LEITURA (Fix 3b): busca na base de conhecimento por (query, kind), reusando
# Ai::KnowledgeRetriever com kinds:[kind]. SOMENTE leitura. Instanciada com o contexto do turno e
# anexada via with_tools SÓ ao vivo. Retorna os trechos encontrados (ou aviso curto), nunca crash.
class Ai::Tools::BuscaConhecimento < RubyLLM::Tool
  description 'Busca informações na base de conhecimento da empresa por um tema. Use quando precisar ' \
              'de dados que não estão no catálogo (dúvidas, procedimentos, documentos).'

  KINDS = %w[produto faq procedimento documento].freeze

  param :query, type: 'string', desc: 'O que buscar, em poucas palavras (ex.: "prazo de instalação").'
  param :kind, type: 'string', desc: "Tipo do conhecimento: um de #{KINDS.join(', ')}."

  def name
    'busca_conhecimento'
  end

  def initialize(account_id:, department_id:, on_read: nil)
    super()
    @account_id = account_id
    @department_id = department_id
    @on_read = on_read
  end

  def execute(query:, kind: nil)
    kinds = KINDS.include?(kind.to_s) ? [kind.to_s] : nil # kind inválido -> sem filtro (não trava a busca)
    chunks = Ai::KnowledgeRetriever.retrieve(query: query.to_s, account_id: @account_id,
                                             department_id: @department_id, kinds: kinds)
    @on_read&.call('busca_conhecimento', { 'query' => query.to_s.first(120), 'kind' => kind.to_s }, chunks)
    return 'Nada encontrado na base para essa busca.' if chunks.empty?

    "Conhecimento encontrado (use APENAS isto; não invente):\n#{chunks.join("\n---\n")}"
  rescue StandardError => e
    Rails.logger.error "[Ai::Tools::BuscaConhecimento] #{e.class}: #{e.message}"
    'Não foi possível consultar a base de conhecimento agora.'
  end
end
