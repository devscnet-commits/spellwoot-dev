require 'rails_helper'

RSpec.describe Ai::ContextBuilder do
  subject(:builder) { described_class.new(conversation: conversation, message: current_message, account: account) }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:current_message) do
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: 'oi')
  end

  def incoming(content, attachment: nil)
    msg = create(:message, conversation: conversation, account: account, inbox: inbox,
                           message_type: :incoming, content: content)
    msg.attachments.create!(attachment.merge(account_id: account.id)) if attachment
    msg
  end

  def outgoing(content)
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: :outgoing, content: content)
  end

  # BUG 3 Parte B: mensagens só-anexo (content vazio) viravam "Cliente: " e eram descartadas do histórico
  # -> a IA "não via" a localização/comprovante e reperguntava. Agora entram como placeholder pelo tipo.
  describe '#user_message — placeholder de anexo no histórico' do
    it 'renderiza localização só-anexo como placeholder (antes era descartada)' do
      incoming('', attachment: { file_type: :location, coordinates_lat: -26.5, coordinates_long: -53.0 })
      outgoing('recebido')

      text = builder.user_message('e agora?')

      expect(text).to include('Cliente: [enviou uma localização]')
    end

    it 'renderiza documento com o nome do arquivo' do
      incoming('', attachment: { file_type: :file, fallback_title: 'comprovante.pdf' })
      outgoing('ok')

      expect(builder.user_message('e agora?')).to include('Cliente: [enviou um documento: comprovante.pdf]')
    end

    it 'renderiza imagem só-anexo como placeholder' do
      incoming('', attachment: { file_type: :image, external_url: 'https://x/y.png' })
      outgoing('ok')

      expect(builder.user_message('e agora?')).to include('Cliente: [enviou uma imagem]')
    end

    it 'mensagem de texto normal continua com o texto (não vira placeholder)' do
      incoming('meu nome é Jaque')
      outgoing('ok')

      text = builder.user_message('e agora?')
      expect(text).to include('Cliente: meu nome é Jaque')
      expect(text).not_to include('[enviou')
    end

    it 'mensagem sem texto e sem anexo continua descartada (linha vazia)' do
      incoming('')
      outgoing('ok')

      expect(builder.user_message('e agora?')).not_to include('Cliente: ')
    end
  end
end
