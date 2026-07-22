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
  string :handoff_target, description: 'Nome EXATO do time/IA de destino; vazio se não aplicável.'
  string :current_step, description: 'Nome da etapa atual (confirmação/registro; não decide o avanço).'
  boolean :step_completed, description: 'true SOMENTE no turno em que concluir a etapa atual; senão false.'
  number :confidence, description: 'Confiança de 0.0 a 1.0.'

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
