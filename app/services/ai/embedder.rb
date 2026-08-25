require 'ruby_llm'

# Embedder de conhecimento com chave "quente" e erro classificado. Diferente do
# Captain::Llm::EmbeddingService (que usa a config GLOBAL do RubyLLM, cravada UMA vez no boot via
# Llm::Config e só recarrega em restart), este resolve a chave FRESCA e monta um contexto próprio
# do RubyLLM por instância — então trocar a chave na tela do sistema passa a valer no PRÓXIMO job,
# sem reiniciar processo.
#
# Uso: instanciar UMA vez por execução de job e reusar o mesmo contexto para todos os pieces
#   emb = Ai::Embedder.new
#   emb.enabled?         # false quando não há chave configurada
#   emb.embed(texto)     # vetor, ou levanta TransientError / AuthError
#
# Classificação de erro (crucial para não re-tentar o que não adianta):
#   - AuthError      -> 401/403/402/400 (chave inválida/revogada, billing, request inválido):
#                       PERMANENTE. Tratado como "sem chave" — grava sem vetor, NÃO re-tenta.
#   - TransientError -> 429/5xx/timeout/rede/desconhecido: re-tentável (Sidekiq retry do job).
class Ai::Embedder
  # Chave inválida/revogada ou request inválido: re-tentar não resolve. Degrada (sem vetor).
  class AuthError < StandardError; end
  # Rate limit / erro de servidor / timeout / rede: transitório, o job deve re-tentar.
  class TransientError < StandardError; end

  DEFAULT_MODEL = (defined?(LlmConstants) ? LlmConstants::DEFAULT_EMBEDDING_MODEL : 'text-embedding-3-small').freeze

  def initialize
    @key = self.class.resolve_key
    @model = self.class.resolve_model
    @context = build_context(@key)
  end

  # Há chave configurada? Sem chave, o caller degrada (grava chunk sem vetor; o RAG cai no ILIKE).
  def enabled?
    !@context.nil?
  end

  # Retorna o vetor do texto. Só deve ser chamado quando enabled?. Levanta AuthError (permanente)
  # ou TransientError (re-tentável) — o job decide degradar vs propagar para o retry.
  def embed(text)
    return nil if text.to_s.strip.blank?

    @context.embed(text, model: @model).vectors
  rescue RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError,
         RubyLLM::PaymentRequiredError, RubyLLM::BadRequestError => e
    raise AuthError, e.message
  rescue StandardError => e
    raise TransientError, "#{e.class}: #{e.message}"
  end

  # Atalho one-shot para quem só quer degradar em nil (ex.: o KnowledgeRetriever embutindo a
  # PERGUNTA): sem chave OU chave inválida => nil. Erro transitório sobe (o caller trata).
  def self.embed(text)
    embedder = new
    return nil unless embedder.enabled?

    embedder.embed(text)
  rescue AuthError => e
    Rails.logger.warn "[Ai::Embedder] chave inválida/revogada — sem embedding: #{e.message}"
    nil
  end

  # Chave GLOBAL da plataforma (mesma fonte do fluxo de resposta), lida FRESCA a cada instância.
  # Embedding não usa BYOK da conta — é sempre a chave do sistema.
  def self.resolve_key
    Ai::ModelRouter.credential('CAPTAIN_OPEN_AI_API_KEY', 'OPENAI_API_KEY')
  rescue StandardError => e
    Rails.logger.warn "[Ai::Embedder] resolve_key via ModelRouter falhou (#{e.class}), caindo pro ENV: #{e.message}"
    ENV.fetch('OPENAI_API_KEY', nil)
  end

  def self.resolve_model
    (InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence if defined?(InstallationConfig)) ||
      DEFAULT_MODEL
  end

  def self.resolve_endpoint
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value.presence if defined?(InstallationConfig)
  end

  private

  # Contexto ISOLADO do RubyLLM com a chave resolvida (nunca toca a config global). nil quando não
  # há chave — sinaliza "embeddings desligados" para o caller degradar.
  def build_context(key)
    return nil if key.blank?

    endpoint = self.class.resolve_endpoint
    RubyLLM.context do |c|
      c.openai_api_key = key
      c.openai_api_base = endpoint.chomp('/') if endpoint.present?
    end
  end
end
