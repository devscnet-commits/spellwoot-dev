# Converte uma imagem enviada para o padrão de figurinha do WhatsApp:
# WebP 512x512, quadrado, com fundo transparente.
# - GIF animado  -> WebP ANIMADO (frame a frame, preservando os tempos de cada quadro).
# - PNG/JPG/GIF estático -> WebP estático 512x512 transparente.
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

    if animated?(source)
      build_animated_webp(source) || convert_static(source)
    else
      convert_static(source)
    end
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

  # --- Detecção -----------------------------------------------------------------

  def animated?(source)
    require 'vips'
    image = Vips::Image.new_from_file(source, n: -1, access: :random)
    pages = image.get_typeof('n-pages').nonzero? ? image.get('n-pages').to_i : 1
    pages > 1
  rescue StandardError
    false
  end

  # --- WebP animado (raw libvips) ----------------------------------------------

  def build_animated_webp(source)
    require 'vips'
    image = Vips::Image.new_from_file(source, n: -1, access: :random)
    page_height = image.get('page-height')
    pages = image.get('n-pages').to_i

    frames = (0...pages).map do |i|
      pad_square(image.crop(0, i * page_height, image.width, page_height))
    end

    result = Vips::Image.arrayjoin(frames, across: 1).copy
    result.set('page-height', TARGET)

    out = Tempfile.new(['sticker', '.webp'])
    out.binmode
    result.webpsave(out.path, strip: true, **animation_options(image))
    # Reabre do disco: webpsave grava no path por fora do handle do Tempfile.
    File.open(out.path, 'rb')
  rescue StandardError => e
    Rails.logger.warn "[Stickers] webp animado falhou: #{e.message}"
    nil
  end

  # Redimensiona o quadro pra caber em 512 e centraliza num canvas 512x512 transparente.
  def pad_square(frame)
    frame = frame.colourspace(:srgb) unless frame.interpretation == :srgb
    frame = frame.bandjoin(255) unless frame.has_alpha?

    scale = [TARGET.to_f / frame.width, TARGET.to_f / frame.height].min
    resized = frame.resize(scale)
    left = ((TARGET - resized.width) / 2.0).round
    top = ((TARGET - resized.height) / 2.0).round
    resized.embed(left, top, TARGET, TARGET, extend: :background, background: [0, 0, 0, 0])
  end

  # Repassa delay (ms por quadro) e loop pro webpsave manter a animação.
  def animation_options(image)
    opts = {}
    opts[:delay] = image.get('delay') if image.get_typeof('delay').nonzero?
    opts[:loop] = image.get('loop').to_i if image.get_typeof('loop').nonzero?
    opts
  end

  # --- WebP estático ------------------------------------------------------------

  def convert_static(source)
    convert_with_vips(source) || convert_with_mini_magick(source)
  end

  def convert_with_vips(source)
    require 'image_processing/vips'

    result = ImageProcessing::Vips
             .source(source)
             .resize_and_pad(TARGET, TARGET, alpha: true) # quadrado + sobras transparentes
             .convert('webp')
             .saver(strip: true) # remove ICC/EXIF — o WhatsApp recusa figurinha com metadados
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
               cmd.strip # remove ICC/EXIF
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
