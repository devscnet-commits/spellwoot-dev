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

  # Deixa a conversa "pronta para pular": nós falamos por último (outgoing) e não é a 1ª mensagem.
  def we_spoke_last
    add_message('outgoing', 'Prontinho, cadastro concluído! 😊')
  end

  describe '.skip?' do
    context 'condição a (texto trivial)' do
      it 'pula "Obrigada!!" (caixa/pontuação) após msg nossa, sem slot — reason closed_list' do
        we_spoke_last
        result = described_class.skip?(text: 'Obrigada!!', conversation: conversation, step: info_step)
        expect(result).to eq(skip: true, reason: 'closed_list')
      end

      it 'pula "👍👍" (só emoji) — reason emoji_only' do
        we_spoke_last
        result = described_class.skip?(text: '👍👍', conversation: conversation, step: info_step)
        expect(result).to eq(skip: true, reason: 'emoji_only')
      end

      it 'NÃO pula "sim" em cenário nenhum (fora da lista v1 — camada 1)' do
        we_spoke_last
        result = described_class.skip?(text: 'sim', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'not_trivial')
      end

      it 'NÃO pula "blz 👍" (misto texto+emoji — nem lista exata nem só emoji)' do
        we_spoke_last
        result = described_class.skip?(text: 'blz 👍', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'not_trivial')
      end

      it 'NÃO pula "ok, e o preço?" (conteúdo além do trivial)' do
        we_spoke_last
        result = described_class.skip?(text: 'ok, e o preço?', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'not_trivial')
      end
    end

    context 'condição b (nós falamos por último)' do
      it 'NÃO pula "ok" quando a última mensagem é INCOMING' do
        add_message('outgoing', 'Posso ajudar em algo?')
        add_message('incoming', 'ok') # cliente falou por último
        result = described_class.skip?(text: 'ok', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'last_incoming')
      end
    end

    context 'condição c (etapa ativa coletando slot)' do
      it 'NÃO pula "ok" (item da lista) quando a etapa atual coleta um slot' do
        we_spoke_last
        result = described_class.skip?(text: 'ok', conversation: conversation, step: slot_step)
        expect(result).to eq(skip: false, reason: 'active_slot')
      end
    end

    context 'condição d (primeira mensagem)' do
      it 'NÃO pula um trivial que é a 1ª mensagem da conversa (sem penúltima)' do
        # "obrigada" é trivial; como não há mensagem anterior, cai na condição d.
        result = described_class.skip?(text: 'obrigada', conversation: conversation, step: info_step)
        expect(result).to eq(skip: false, reason: 'first_message')
      end

      it 'NÃO pula a 1ª mensagem "oi" (também não é trivial — a falha em a)' do
        result = described_class.skip?(text: 'oi', conversation: conversation, step: info_step)
        expect(result[:skip]).to be(false)
      end
    end

    context 'comportamento emergente: dois "obrigada" seguidos' do
      it 'pula o PRIMEIRO e NÃO pula o SEGUNDO (a última mensagem virou incoming)' do
        we_spoke_last # outgoing

        # 1º "obrigada": nós falamos por último -> pula.
        first = described_class.skip?(text: 'obrigada', conversation: conversation, step: info_step)
        expect(first).to eq(skip: true, reason: 'closed_list')

        # Como pulamos, NÃO enviamos nada; o cliente insistiu (a msg dele foi gravada).
        add_message('incoming', 'obrigada')
        second = described_class.skip?(text: 'obrigada', conversation: conversation, step: info_step)
        expect(second).to eq(skip: false, reason: 'last_incoming')
      end
    end
  end
end
