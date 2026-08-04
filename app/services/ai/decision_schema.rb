# Structured Output (strict) da chamada de DECISÃO do supervisor. Substitui o response_format
# json_object frouxo: o enum de `decision` é imposto pelo provider, então "decision inventado"
# ('text'/'message'/'resposta'...) fica ELIMINADO POR CONSTRUÇÃO.
#
# Strict da OpenAI exige additionalProperties:false + campos tipados (sem objeto de forma livre). Os
# DOIS campos livres do envelope viram formas fechadas e são RE-normalizados no Ai::ModelRouter:
#   - tool.input (schema varia por tool) -> tool_input_json: STRING contendo JSON;
#   - attributes (chaves dinâmicas)      -> attributes_list: ARRAY de {key, value}.
#
# COMPAT COM O FIX 3b (separação decisão/resposta): o schema está dividido em (A) NÚCLEO DE DECISÃO —
# o que o 3b mantém — e (B) reply_text TRANSITÓRIO. Remover reply_text no 3b é apagar UMA linha (o
# núcleo não referencia reply_text em lugar nenhum).
#
# ruby_llm-schema 0.2.5: toda propriedade nasce required:true, additional_properties=false e
# strict=true por padrão — exatamente o que o strict da OpenAI pede. "Ausente" é representado por
# "" / "{}" / [] (documentado abaixo), não por omissão do campo.
class Ai::DecisionSchema < RubyLLM::Schema
  # ===================== (A) NÚCLEO DE DECISÃO (mantido no Fix 3b) =====================
  string :decision, enum: %w[reply invoke_tool handoff close noop],
                    description: "Próxima ação. SOMENTE um destes 5 valores."

  # Ferramenta: nome + input como STRING JSON (forma fechada p/ o strict). tool_name "" = nenhuma
  # ferramenta; tool_input_json "{}" quando não houver ferramenta. Re-montados em tool{name,input}.
  string :tool_name, description: 'Nome EXATO da ferramenta a chamar; string vazia se nenhuma.'
  string :tool_input_json, description: 'Input da ferramenta como STRING JSON (ex.: um objeto); "{}" se nenhuma.'

  string :handoff_reason, description: 'Motivo do handoff; vazio se não aplicável.'
  # 4ª aplicação do padrão "descrição vaga → modelo preenche errado" (após asked_slot, proposed_value,
  # handoff_summary). O modelo inventava uma CATEGORIA genérica ("Assistente", "suporte", "comercial")
  # em vez de copiar o nome real da whitelist → não casava → motor caia no fallback (time errado).
  # Contrato explícito: só nome da LISTA; nunca categoria; vazio se nenhum nome da lista servir.
  string :handoff_target, description: 'O NOME EXATO de um time ou IA da lista de transferência ' \
                                       'mostrada no prompt (copie exatamente como está escrito). ' \
                                       'NUNCA uma categoria ou função genérica ("suporte", "comercial", ' \
                                       '"assistente"): se nenhum nome da lista servir, deixe vazio.'
  string :current_step, description: 'Nome da etapa atual (confirmação/registro; não decide o avanço).'
  boolean :step_completed, description: 'true SOMENTE no turno em que concluir a etapa atual; senão false.'
  number :confidence, description: 'Confiança de 0.0 a 1.0.'

  # Contrato pergunta↔etapa: a CHAVE do slot que a sua reply_text está pedindo NESTE turno. required:true
  # (0.2.5); "" = a resposta não pede dado (saudação/encerramento/confirmação), mesma convenção de
  # tool_name/handoff_reason. O motor usa isto para (a) rotear a resposta do cliente ao slot certo — o
  # destino da captura passa a seguir a PERGUNTA — e (b) medir dessincronia (slot.asked_desync) quando
  # difere do slot da etapa corrente. NÃO decide o avanço (isso segue o slot da etapa).
  string :asked_slot, description: 'A chave EXATA do slot que a sua reply_text está pedindo neste turno. ' \
                                   'Inclui perguntas de escolha, permissão ou confirmação cuja resposta ' \
                                   'preenche o slot. Vazio SÓ quando a resposta do cliente não preenche slot nenhum.'

  # Proposta de valor para confirmação (Frente B). Quando a sua reply_text PROPÕE um valor concreto ao
  # cliente e pede um sim/não (ex.: só há um horário disponível -> "posso reservar para a TARDE?"), preencha
  # com esse valor ("tarde"). required:true (0.2.5); "" = a resposta NÃO propõe valor (pergunta aberta,
  # saudação, confirmação de dado já dito). O motor guarda o proposto junto do asked_slot; se o próximo turno
  # do cliente CONFIRMAR (juiz -> 'confirmed'), grava-se o VALOR PROPOSTO no slot — nunca o texto "sim".
  string :proposed_value, description: 'Valor que a sua reply_text propõe ao cliente p/ confirmação neste turno; vazio se não propõe.'

  # Atributos coletados como lista fechada {key,value} (o strict não aceita objeto de chaves dinâmicas).
  # Re-normalizado para o Hash `attributes` interno. [] quando não houver nada novo.
  array :attributes_list, description: 'Dados coletados do cliente; [] se nada novo.' do
    object do
      string :key, description: 'Chave EXATA do atributo.'
      string :value, description: 'Valor informado pelo cliente.'
    end
  end

  # ===================== (B) CAMPO DE TEXTO TRANSITÓRIO =====================
  # TRANSITÓRIO — removido no Fix 3b quando a RESPOSTA ao cliente virar uma chamada separada. Nenhuma
  # validação/normalização do NÚCLEO depende deste campo: deletar a linha abaixo não afeta o núcleo.
  string :reply_text, description: 'Texto ao cliente (transitório; sairá no Fix 3b).'
end
