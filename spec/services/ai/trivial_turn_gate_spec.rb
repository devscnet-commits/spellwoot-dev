require 'rails_helper'

# Camada 0 — triagem determinística de turno trivial (FIX 3d). Testa as condições a–d ISOLADAS, o par
# de camadas que protege a resposta legítima ao slot ("sim"/"não" fora da lista + nunca pular com slot
# ativo) e os comportamentos emergentes documentados (dois "obrigada" seguidos).
#
# Rodar:  docker compose exec rails bundle exec rspec spec/services/ai/trivial_turn_gate_spec.rb
RSpec.describe Ai::TrivialTurnGate do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: 'open') }

  # Cria uma mensagem na conversa (ordem = ordem de criação). Devolve a mensagem.
  def add_message(type, content = 'x')
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: type, content: content)
  end

  # Etapa (hash de playbook) que COLETA um slot obrigatório — dispara a condição c.
  def slot_step
    { 'name' => 'Vencimento', 'collect' => { 'attribute' => 'dia_vencimento', 'type' => 'number' } }
  end

  # Etapa informativa (sem coleta) — condição c não bloqueia.
  def info_step
    { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente o cliente.' }
  end

  # Etapa TERMINAL (on_complete, sem slot) — a condição f. O conclude_ready é passado ao gate (computado
  # pelo StateManager); aqui exercitamos o kwarg direto.
  def terminal_step
    { 'name' => 'Finalização', 'on_complete' => { 'action' => 'handoff_human', 'reason' => 'conclusao' } }
  end

  # Reproduz o estado REAL no momento do gate: a mensagem atual (incoming) JÁ está persistida como a
  # última da conversa — é assim que o Ai::Gateway chama skip? (a mensagem recebida é gravada antes de
  # o gate rodar; previous_message pega a PENÚLTIMA). Aqui: nós respondemos (outgoing = penúltima) e o
  # cliente então mandou <text> (incoming = atual). O texto do gate vem do parâmetro; o conteúdo
  # persistido só serve para o previous_message enxergar a penúltima outgoing.
  def after_our_reply(text)
    add_message('outgoing', 'Prontinho, cadastro concluído! 😊')
    add_message('incoming', text)
  end

  describe '.skip?' do
    context 'condição a (texto trivial)' do
      it 'pula "Obrigada!!" (caixa/pontuação) após msg nossa, sem slot — reason closed_list' do
        after_our_reply('Obrigada!!')
        result = described_class.skip?(text: 'Obrigada!!', conversation: conversation, step: info_step)
        expect(result).to eq(skip: true, reason: 'closed_list')
      end

      it 'pula "👍👍" (só emoji) — reason emoji_only' do
        after_our_reply('👍👍')
        result = described_class.skip?(text: '👍👍', conversation: conversation, step: info_step)
        expect(result).to eq(skip: true, reason: 'emoji_only')
      end

      it 'NÃO pula "sim" em cenário nenhum (fora da lista v1 — camada 1)' do
        after_our_reply('sim')
        result = described_class.skip?(text: 'sim', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'not_trivial')
      end

      it 'NÃO pula "blz 👍" (misto texto+emoji — nem lista exata nem só emoji)' do
        after_our_reply('blz 👍')
        result = described_class.skip?(text: 'blz 👍', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'not_trivial')
      end

      it 'NÃO pula "ok, e o preço?" (conteúdo além do trivial)' do
        after_our_reply('ok, e o preço?')
        result = described_class.skip?(text: 'ok, e o preço?', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'not_trivial')
      end
    end

    context 'condição b (nós falamos por último)' do
      it 'NÃO pula "ok" quando a mensagem ANTERIOR à atual é INCOMING (o cliente falou por último)' do
        add_message('incoming', 'oi, tudo bem?') # penúltima = incoming (cliente já vinha falando)
        add_message('incoming', 'ok')            # mensagem atual (persistida)
        result = described_class.skip?(text: 'ok', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'last_incoming')
      end
    end

    context 'condição f (etapa TERMINAL pronta para concluir)' do # rubocop:disable RSpec/ContextWording
      # BUG: em etapa terminal (on_complete, sem slot) com o funil completo, "ok" é o ACEITE que dispara a
      # conclusão determinística. As guardas c/e leem "nada esperando" (sem slot, last_asked nil) e engoliam
      # -> a conversa ficava parada sem transferir. A 3ª guarda (conclude_ready) não deixa pular.
      it 'NÃO pula "ok" quando conclude_ready (aceite da transição) — reason terminal_ready' do
        after_our_reply('ok')
        result = described_class.skip?(text: 'ok', conversation: conversation, step: terminal_step, conclude_ready: true)
        expect(result).to eq(skip: false, reason: 'terminal_ready')
      end

      # PROVA DE MUTAÇÃO: a MESMA etapa terminal + "ok", mas sem conclude_ready, ainda pula (era o bug). Se a
      # guarda (f) sumir, o teste de cima passa a pular também.
      it 'sem conclude_ready, a mesma etapa terminal + "ok" ainda pula (closed_list)' do
        after_our_reply('ok')
        result = described_class.skip?(text: 'ok', conversation: conversation, step: terminal_step, conclude_ready: false)
        expect(result).to eq(skip: true, reason: 'closed_list')
      end
    end

    context 'condição c (slot PENDENTE não preenchido)' do
      # O gate lê o valor coletado em additional_attributes['ai_collected_facts'].
      def set_facts(facts)
        conversation.update!(additional_attributes:
          (conversation.additional_attributes || {}).merge('ai_collected_facts' => facts))
      end

      it 'NÃO pula "ok" quando a etapa tem slot SEM valor (pendente) — reason pending_slot' do
        after_our_reply('ok')
        result = described_class.skip?(text: 'ok', conversation: conversation, step: slot_step)
        expect(result).to eq(skip: false, reason: 'pending_slot')
      end

      # Afrouxamento deliberado: slot já preenchido + sem pergunta pendente = fim de conversa -> pula.
      it 'PULA "ok" quando o slot da etapa JÁ está preenchido (economia de fim de conversa)' do
        after_our_reply('ok')
        set_facts('dia_vencimento' => '10')
        result = described_class.skip?(text: 'ok', conversation: conversation, step: slot_step)
        expect(result).to eq(skip: true, reason: 'closed_list')
      end

      it 'PULA "ok" quando o slot está resolvido por ABSENT (ausência aceita, NÃO é pendente)' do
        after_our_reply('ok')
        set_facts('dia_vencimento' => Ai::StepSlot::ABSENT)
        result = described_class.skip?(text: 'ok', conversation: conversation, step: slot_step)
        expect(result).to eq(skip: true, reason: 'closed_list')
      end
    end

    # Reprodução EXATA da conv 412: a IA perguntou "vou finalizar seu pré-cadastro, tudo bem?" numa etapa
    # SEM collect -> StepSlot.attribute nil -> a condição (c) NÃO vê slot algum. Mas asked_slot foi gravado
    # -> ai_last_asked_slot presente -> o "ok" é a RESPOSTA. Falha por mutação se só a (c) for implementada.
    context 'condição e (turno anterior fez pergunta — ai_last_asked_slot) — conv 412' do
      def set_asked_slot(slot)
        conversation.update!(additional_attributes:
          (conversation.additional_attributes || {}).merge('ai_last_asked_slot' => slot))
      end

      it 'NÃO pula "ok" em etapa SEM collect quando ai_last_asked_slot presente — reason awaiting_answer' do
        after_our_reply('ok')
        set_asked_slot('confirma_finalizacao')
        result = described_class.skip?(text: 'ok', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'awaiting_answer')
      end

      it 'sem ai_last_asked_slot em etapa sem collect: "ok" volta a pular (fim de conversa)' do
        after_our_reply('ok')
        result = described_class.skip?(text: 'ok', conversation: conversation, step: info_step)
        expect(result).to eq(skip: true, reason: 'closed_list')
      end
    end

    context 'condição d (primeira mensagem)' do
      it 'NÃO pula um trivial que é a 1ª mensagem da conversa (sem penúltima)' do
        add_message('incoming', 'obrigada') # única mensagem = a atual; não há penúltima -> condição d
        result = described_class.skip?(text: 'obrigada', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'first_message')
      end

      it 'NÃO pula a 1ª mensagem "oi" (também não é trivial — a falha em a)' do
        add_message('incoming', 'oi')
        result = described_class.skip?(text: 'oi', conversation: conversation, step: info_step)
        expect(result[:skip]).to be(false)
      end
    end

    context 'comportamento emergente: dois "obrigada" seguidos' do
      it 'pula o PRIMEIRO e NÃO pula o SEGUNDO (a mensagem anterior virou incoming)' do
        after_our_reply('obrigada') # outgoing (penúltima) + incoming atual (1º "obrigada")

        # 1º "obrigada": penúltima é a nossa resposta -> pula.
        first = described_class.skip?(text: 'obrigada', conversation: conversation, step: info_step)
        expect(first).to eq(skip: true, reason: 'closed_list')

        # Como pulamos, NÃO enviamos nada; o cliente insistiu (a msg dele foi gravada). Agora a penúltima
        # é o 1º "obrigada" (incoming), então o 2º NÃO pula.
        add_message('incoming', 'obrigada')
        second = described_class.skip?(text: 'obrigada', conversation: conversation, step: info_step)
        expect(second).to eq(skip: false, reason: 'last_incoming')
      end
    end
  end
end
