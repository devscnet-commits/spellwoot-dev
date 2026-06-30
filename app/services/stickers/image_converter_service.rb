# Converte uma imagem enviada (PNG/JPG/GIF) para o padrão de figurinha do WhatsApp:
# WebP 512x512, quadrado, com fundo transparente (preenche as sobras com alpha).
# Retorna um Tempfile pronto pra anexar, ou nil se não for possível (aí mantém o original).
class Stickers::ImageConverterService
  TARGET = 512

  def self.call(uploaded_file)
    new(uploaded_file).call
  end

  def initialize(uploaded_file)
    @uploaded_file = uploaded_file
  end

  def call
    return nil if @uploaded_file.blank?

    source = source_path
    return nil if source.blank?

    convert_with_vips(source) || convert_with_mini_magick(source)
  rescue StandardError => e
    Rails.logger.warn "[Stickers] conversao falhou: #{e.class}: #{e.message}"
    nil
  end

  private

  def source_path
    return @uploaded_file.tempfile.path if @uploaded_file.respond_to?(:tempfile)
    return @uploaded_file.path if @uploaded_file.respond_to?(:path)

    nil
  end

  def convert_with_vips(source)
    require 'image_processing/vips'

    result = ImageProcessing::Vips
             .source(source)
             .resize_and_pad(TARGET, TARGET, alpha: true) # quadrado + sobras transparentes
             .convert('webp')
             .call
    rewind(result)
  rescue LoadError, StandardError => e
    Rails.logger.warn "[Stickers] vips indisponivel/falhou: #{e.message}"
    nil
  end

  def convert_with_mini_magick(source)
    require 'image_processing/mini_magick'

    result = ImageProcessing::MiniMagick
             .source(source)
             .resize_to_fit(TARGET, TARGET)
             .convert('webp')
             .call do |cmd|
               cmd.background 'none'
               cmd.gravity 'center'
               cmd.extent "#{TARGET}x#{TARGET}"
             end
    rewind(result)
  rescue StandardError => e
    Rails.logger.warn "[Stickers] mini_magick falhou: #{e.message}"
    nil
  end

  def rewind(file)
    file.rewind if file.respond_to?(:rewind)
    file
  end
end
