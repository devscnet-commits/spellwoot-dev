# Gap 1 (recusa/ausência de slot) — DETECÇÃO de que o cliente declinou o dado que a etapa coleta
# ("não tenho", "não possui", "não informado"…). Fonte ÚNICA, ortogonal ao tipo do slot e chamada ANTES
# da validação de formato — é o que impede o loop de repergunta (email/telefone/cpf) e o valor de recusa
# virar dado num slot de texto.
#
# Estratégia A+B (design v2, 4.1):
#   A — sentinela instruída: o PromptCompiler pede ao modelo devolver Ai::StepSlot::ABSENT quando o
#       cliente declinar; casamos o token no VALOR de `attributes[slot]`.
#   B — rede por expressão: lista fechada de frases de recusa (normalizadas). Casada por IGUALDADE no
#       valor do modelo (curto/controlado) e no texto do turno; por INCLUSÃO só as ANCORADAS num dado
#       (evita falso-positivo como "não tenho tempo" numa etapa de e-mail).
#
# Guard (d): se o EXTRACTOR do slot encontra um valor válido no texto ("não tenho email mas usa
# joao@x.com"), ausência NÃO se aplica — captura o valor. O guard roda PRIMEIRO.
module Ai::SlotAbsence
  module_function

  # Casadas por IGUALDADE (a mensagem/valor É a recusa). "nao tenho" exato = recusa; "nao tenho tempo"
  # (≠ exato) NÃO casa aqui.
  EXACT = ['nao tenho', 'nao possuo', 'nao possui', 'nao informado', 'nao informar', 'nao tenho um',
           'nao tenho nenhum', 'nao quero informar', 'prefiro nao informar', 'prefiro nao passar',
           'sem email', 'nao sei'].freeze

  # Casadas por INCLUSÃO (frase ancorada num dado — segura contra falso-positivo genérico).
  ANCHORED = ['nao tenho email', 'nao tenho e mail', 'nao possuo email', 'sem e mail', 'nao tenho cpf',
              'nao tenho telefone', 'nao tenho celular', 'nao tenho whatsapp', 'nao quero informar',
              'prefiro nao informar', 'prefiro nao passar'].freeze

  # → true quando o turno é uma RECUSA do dado do slot. value = attributes[slot] do modelo (pode ser
  # nil); text = mensagem do turno; type/options = tipo efetivo do slot (para o guard (d)).
  def declined?(value:, text:, type:, options:)
    return false if extractable?(type, text, options) # (d) valor válido no texto vence a recusa

    absence_value?(value) || absence_text?(text)
  end

  # Só o VALOR (o gate do supervisor não tem o texto do turno): token OU expressão exata. Impede o valor
  # cru de recusa do modelo ("não informado") de virar fato num slot de texto.
  def absence_value?(value)
    return true if Ai::StepSlot.absent?(value)

    norm = Ai::SlotExtractor.normalize(value.to_s)
    norm.present? && EXACT.include?(norm)
  end

  # Texto do turno: expressão exata OU frase ancorada por inclusão.
  def absence_text?(text)
    norm = Ai::SlotExtractor.normalize(text.to_s)
    return false if norm.empty?

    EXACT.include?(norm) || ANCHORED.any? { |a| norm.include?(a) }
  end

  # (d) O extractor do slot acha um valor válido no texto? (só tipos de formato conhecido; texto puro
  # nunca extrai → não bloqueia).
  def extractable?(type, text, options)
    Ai::SlotExtractor.extract(attribute_type: type, text: text.to_s, options: options).present?
  end

  # Palavras de negação (normalizadas) — âncora da heurística de "parece declínio".
  NEGATIONS = %w[nao sem nunca jamais nenhum nem].freeze

  # OBSERVABILIDADE (Gap 4 v2, débito do fraseado novo) — NÃO roteia, só sinaliza. O texto PARECE um
  # declínio que as listas fechadas (EXACT/ANCHORED) não reconheceram? Heurística barata: curto (poucas
  # palavras) e com negação. Alimenta o crescimento das listas com dado real (o TurnCapture emite um evento
  # quando isto é true e o dado caiu em :no_attempt). Só faz sentido chamar DEPOIS de declined? dar false.
  def looks_like_decline?(text)
    norm = Ai::SlotExtractor.normalize(text.to_s)
    return false if norm.empty?

    words = norm.split
    words.size <= 6 && words.intersect?(NEGATIONS)
  end
end
