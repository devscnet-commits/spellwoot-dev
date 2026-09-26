require 'rails_helper'

# Antes desta regra, só WhatsApp e API eram checados no servidor; os outros canais eram escondidos
# apenas no front, então bastava chamar a API para criar um canal que o plano não inclui.
RSpec.describe ChannelAvailability do
  let(:account) { create(:account) }

  describe '.available?' do
    it 'libera canal que o plano da conta declara' do
      subscribe_account_to_plan(account, features: ['whatsapp_channel'])

      expect(described_class.available?(account.reload, 'whatsapp')).to be(true)
    end

    it 'barra canal que o plano da conta NÃO declara' do
      subscribe_account_to_plan(account, features: ['whatsapp_channel'])

      expect(described_class.available?(account.reload, 'web_widget')).to be(false)
    end

    # Conta sem assinatura não pode ser barrada: é o caso de contas internas/dev, e o bitmask dela
    # continua no default do config/features.yml.
    it 'não barra conta sem assinatura' do
      account.enable_features!('channel_whatsapp')

      expect(described_class.available?(account, 'whatsapp')).to be(true)
    end

    it 'canal sem campo no plano (line) passa sempre' do
      subscribe_account_to_plan(account, features: [])

      expect(described_class.available?(account.reload, 'line')).to be(true)
    end
  end

  describe '.filter' do
    it 'devolve só os canais do plano, preservando a ordem' do
      subscribe_account_to_plan(account, features: %w[whatsapp_channel email_channel])

      filtered = described_class.filter(account.reload, %w[web_widget email line whatsapp])

      expect(filtered).to eq(%w[email line whatsapp])
    end
  end

  describe '.unofficial_whatsapp_available?' do
    it 'libera quando o plano traz WhatsApp com "Todas"' do
      subscribe_account_to_plan(account, features: %w[whatsapp_channel whatsapp_unofficial_channel])

      expect(described_class.unofficial_whatsapp_available?(account.reload)).to be(true)
    end

    it 'barra quando o plano é "Somente oficiais"' do
      subscribe_account_to_plan(account, features: %w[whatsapp_channel])

      account.reload
      expect(described_class.available?(account, 'whatsapp')).to be(true)
      expect(described_class.unofficial_whatsapp_available?(account)).to be(false)
    end

    it 'barra quando o plano não tem WhatsApp, mesmo com a flag de não oficial' do
      subscribe_account_to_plan(account, features: %w[whatsapp_unofficial_channel])

      expect(described_class.unofficial_whatsapp_available?(account.reload)).to be(false)
    end
  end

  it 'toda flag do mapa existe em config/features.yml' do
    conhecidas = SuperAdmin::AccountFeaturesHelper.account_features.pluck('name')

    expect(described_class::FEATURE_BY_CHANNEL.values - conhecidas).to be_empty
  end
end
