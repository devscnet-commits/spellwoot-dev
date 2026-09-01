namespace :branding do
  desc 'Aplica o branding customizado da Conexi IA'
  task setup: :environment do
    base_url = ENV.fetch('FRONTEND_URL', 'https://app.conexiia.com.br')

    {
      'LOGO_THUMBNAIL'    => "#{base_url}/brand-assets/favicon-conexi-ia.webp",
      'LOGO'              => "#{base_url}/brand-assets/conexi-ia-cinza.webp",
      'LOGO_DARK'         => "#{base_url}/brand-assets/conexi-ia-branca.webp",
      'BRAND_NAME'        => 'Conexi IA',
      'INSTALLATION_NAME' => 'Conexi IA'
    }.each do |key, value|
      config = InstallationConfig.find_by(name: key)
      next unless config

      config.update!(value: value)
      puts "✔ #{key} => #{value}"
    end
  end
end
