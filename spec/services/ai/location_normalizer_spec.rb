require 'rails_helper'

RSpec.describe Ai::LocationNormalizer do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  # Formato real da integração nativa do uazapi (conv 367/368): pin de estabelecimento, linhas por \n.
  location_text = "📍\n🏷️ SCNET Internet de Fibra\n" \
                  "📌 R. Duque de Caxias, 387, Maravilha, 89874-000, SC, BR\n" \
                  "🧭 -26.764942, -53.177551\n🔗 https://materiais.scnet.com.br/"

  def incoming(text, message_type: :incoming)
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: message_type, content: text)
  end

  def location_attachments(message)
    message.attachments.where(file_type: :location)
  end

  describe '.normalize' do
    it 'texto completo (nome + endereço + coordenadas + link) -> Attachment location correto' do
      msg = incoming(location_text)

      expect { described_class.normalize(msg) }.to change { location_attachments(msg).count }.by(1)

      att = location_attachments(msg).last
      expect(att.coordinates_lat).to eq(-26.764942)
      expect(att.coordinates_long).to eq(-53.177551)
      expect(att.fallback_title).to eq('SCNET Internet de Fibra, R. Duque de Caxias, 387, Maravilha, 89874-000, SC, BR')
      expect(att.external_url).to eq('https://materiais.scnet.com.br/')
    end

    it 'só a linha de coordenadas -> Attachment com lat/long; title e url vazios, sem erro' do
      msg = incoming('-26.5, -53.25')

      described_class.normalize(msg)

      att = location_attachments(msg).last
      expect(att.coordinates_lat).to eq(-26.5)
      expect(att.coordinates_long).to eq(-53.25)
      expect(att.fallback_title).to be_nil
      expect(att.external_url).to be_nil
    end

    it 'emite location.normalized com as coordenadas' do
      msg = incoming(location_text)
      described_class.normalize(msg)

      event = Ai::Event.where(conversation_id: conversation.id, event_type: 'location.normalized').last
      expect(event.payload).to include('coordinates' => '-26.764942,-53.177551',
                                       'url' => 'https://materiais.scnet.com.br/')
    end

    it 'texto normal SEM coordenadas -> não cria nada' do
      msg = incoming('Boa tarde, quero a segunda via da fatura')
      expect { described_class.normalize(msg) }.not_to change(msg.attachments, :count)
    end

    ['pode ser 5, 10 ou 15', 'o valor é R$ 89,90', 'meu whatsapp é 4998564780', '5, 10'].each do |text|
      it "falso positivo: não cria Attachment para #{text.inspect}" do
        msg = incoming(text)
        expect { described_class.normalize(msg) }.not_to change(msg.attachments, :count)
      end
    end

    it 'lat/long FORA de faixa ("200.5, 300.7") -> não cria' do
      msg = incoming('coordenada estranha 200.5, 300.7')
      expect { described_class.normalize(msg) }.not_to change(msg.attachments, :count)
    end

    it 'mensagem que JÁ tem Attachment -> não cria outro (idempotência de escopo)' do
      msg = incoming(location_text)
      msg.attachments.create!(account_id: account.id, file_type: :file, fallback_title: 'doc.pdf')

      expect { described_class.normalize(msg) }.not_to change(msg.attachments, :count)
      expect(location_attachments(msg).count).to eq(0)
    end

    it 'mensagem OUTGOING -> não processa' do
      msg = incoming(location_text, message_type: :outgoing)
      expect { described_class.normalize(msg) }.not_to change(msg.attachments, :count)
    end

    it 'rodar DUAS vezes sobre a mesma mensagem -> um único Attachment (idempotência)' do
      msg = incoming(location_text)

      described_class.normalize(msg)
      described_class.normalize(msg.reload)

      expect(location_attachments(msg).count).to eq(1)
    end

    it 'PDF numa mensagem e localização em OUTRA (mesma conversa): o guard exists? é por-mensagem' do
      # conv 364/367: comprovante (PDF) num turno e a localização em texto num turno seguinte.
      pdf_msg = incoming('segue o comprovante')
      pdf_msg.attachments.create!(account_id: account.id, file_type: :file, fallback_title: 'comprovante.pdf')

      loc_msg = incoming(location_text)
      described_class.normalize(loc_msg)

      # a mensagem do PDF NÃO é afetada (nenhum anexo de location criado nela)
      expect(pdf_msg.reload.attachments.count).to eq(1)
      expect(location_attachments(pdf_msg).count).to eq(0)

      # a mensagem da localização (sem anexo PRÓPRIO) recebe o Attachment :location normalmente
      expect(location_attachments(loc_msg).count).to eq(1)
      expect(location_attachments(loc_msg).last.coordinates_lat).to eq(-26.764942)
      expect(location_attachments(loc_msg).last.coordinates_long).to eq(-53.177551)
    end
  end

  # Integração: depois de normalizado, o miolo do #269/BUG 3 (Ai::TurnCapture#capture_attachment via
  # StateManager#track_step) grava os fatos determinísticos da localização.
  describe 'integração com a captura do turno' do
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
    end
    let(:agent) do
      Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
    end
    before do
      agent.create_playbook!(active: true, steps: [{ 'name' => 'Localização' }, { 'name' => 'Fim' }])
    end

    it 'grava localizacao_recebida / localizacao_coordenadas / localizacao_link' do
      msg = incoming(location_text)
      described_class.normalize(msg)

      Ai::StateManager.new(conversation: conversation, agent: agent)
                      .track_step(agent, { 'step_completed' => false }, message_text: '', message: msg)

      facts = conversation.reload.additional_attributes['ai_collected_facts']
      expect(facts['localizacao_recebida']).to be(true)
      expect(facts['localizacao_coordenadas']).to eq('-26.764942,-53.177551')
      expect(facts['localizacao_link']).to eq('https://materiais.scnet.com.br/')
    end
  end
end
