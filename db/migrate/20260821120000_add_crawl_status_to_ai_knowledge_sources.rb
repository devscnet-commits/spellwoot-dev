# Pedido do dono da conta (21/08): fonte do tipo "website" falhava em silêncio — Ai::SiteCrawlJob só
# logava o erro no servidor, sem NENHUM sinal na tela. A fonte ficava salva, com "raw" vazio, parecendo
# normal enquanto nunca virava conhecimento buscável de verdade. Estas duas colunas dão pro front mostrar
# o estado real (pendente/indexado/falhou) — ver Ai::SiteCrawlJob e AiKnowledge.vue.
class AddCrawlStatusToAiKnowledgeSources < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_knowledge_sources, :crawl_status, :string
    add_column :ai_knowledge_sources, :crawl_error, :text
  end
end
