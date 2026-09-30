require 'rails_helper'
require Rails.root.join('db/migrate/20260930120000_copy_inherited_meta_config_to_accounts.rb')

# A Meta deixou de herdar a config global: quem já enviava conversões pelo Pixel herdado ganha a config como
# sua (nada para de enviar no deploy); quem não enviava fica sem config.
RSpec.describe CopyInheritedMetaConfigToAccounts do
  let(:global) { { 'pixelId' => '931618603010277', 'accessToken' => 'EAA-plataforma', 'testEventCode' => 'TEST81275' } }
  let(:enviando) { create(:account, settings: { 'meta_conversion_settings' => { 'enabled' => true } }) }
  let(:desligada) { create(:account) }
  let(:com_pixel_proprio) { create(:account, settings: { 'meta_conversion_settings' => { 'enabled' => true } }) }
  let(:desativou_meta) { create(:account, settings: { 'meta_conversion_settings' => { 'enabled' => true } }) }

  def meta_config(account)
    IntegrationSetting.find_by(account_id: account.id, provider: 'meta')&.config_hash
  end

  before do
    IntegrationSetting.create!(account_id: nil, provider: 'meta', enabled: true, config: global.to_json)
    IntegrationSetting.create!(account_id: com_pixel_proprio.id, provider: 'meta', enabled: true,
                               config: { pixelId: 'pixel-cliente', accessToken: 'token-cliente' }.to_json)
    IntegrationSetting.create!(account_id: desativou_meta.id, provider: 'meta', enabled: false, config: '{}')
    [enviando, desligada]
    described_class.new.migrate(:up)
  end

  it 'conta que enviava pelo Pixel herdado: passa a ter a config como sua e continua enviando' do
    expect(meta_config(enviando)).to eq(global)
    expect(IntegrationSettingsService.get_config(enviando.id, 'meta')).to eq(global)
  end

  it 'conta com o interruptor desligado: continua sem config' do
    expect(meta_config(desligada)).to be_nil
  end

  it 'conta com Pixel próprio: não é tocada' do
    expect(meta_config(com_pixel_proprio)).to eq('pixelId' => 'pixel-cliente', 'accessToken' => 'token-cliente')
  end

  it 'conta que desativou a Meta: não é tocada' do
    expect(meta_config(desativou_meta)).to eq({})
  end
end
