# O modo sombra passou a ser DESLIGADO por padrão (Ai::ShadowPolicy) — ele faz a chamada paga ao
# modelo e não entrega resposta, e estava gastando em produção sem ninguém ter configurado sombra.
# Os testes que exercitam o comportamento de sombra precisam ligá-lo de forma explícita, que é
# exatamente o que se espera de quem quiser ligar em produção.
module AiShadowHelpers
  def enable_shadow!
    allow(Ai::ShadowPolicy).to receive(:enabled?).and_return(true)
  end
end
