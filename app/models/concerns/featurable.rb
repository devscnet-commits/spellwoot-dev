module Featurable
  extend ActiveSupport::Concern

  # Fonte da verdade das features: config/features.yml, na ordem do arquivo.
  # Antes o Featurable empacotava cada feature num bit de accounts.feature_flags (bigint) via
  # FlagShihTzu — o que travava o sistema em 63 features (o 64o bit estoura o bigint com sinal).
  # Agora o estado vive em accounts.enabled_feature_keys (text[]: sem teto, legivel, indexado por
  # GIN) e este concern reimplementa a MESMA API publica sobre o array. A coluna feature_flags
  # continua no banco (nao e mais lida nem escrita) ate o passo final da migracao, que a dropa
  # apos soak em producao. Ver a migracao 20260701120000 e as rake tasks feature_flags:*.
  FEATURE_LIST = YAML.safe_load(Rails.root.join('config/features.yml').read).freeze
  FEATURE_NAMES = FEATURE_LIST.pluck('name').freeze

  included do
    before_create :enable_default_features

    # Recria, feature a feature, a superficie dinamica que o has_flags gerava — agora sobre o array:
    #  - predicado de instancia  feature_<x>?      (ex.: account.feature_ai_core?)
    #  - setter de instancia     feature_<x>=       (ex.: send('feature_advanced_assignment=', true))
    #  - scopes de classe        feature_<x> / not_feature_<x>  (ex.: Account.feature_assignment_v2)
    # O GIN em enabled_feature_keys da suporte eficiente ao operador de contencao @>.
    FEATURE_NAMES.each do |feature_name|
      define_method("feature_#{feature_name}?") { feature_enabled?(feature_name) }

      define_method("feature_#{feature_name}=") do |value|
        ActiveModel::Type::Boolean.new.cast(value) ? enable_features(feature_name) : disable_features(feature_name)
      end

      scope "feature_#{feature_name}", -> { where('enabled_feature_keys @> ARRAY[?]::varchar[]', feature_name) }
      scope "not_feature_#{feature_name}", -> { where.not('enabled_feature_keys @> ARRAY[?]::varchar[]', feature_name) }
    end
  end

  # --- API publica (assinaturas identicas as anteriores) --------------------------------

  def feature_enabled?(name)
    enabled_feature_keys.include?(name.to_s)
  end

  def enable_features(*names)
    self.enabled_feature_keys = (enabled_feature_keys | names.map(&:to_s))
  end

  def enable_features!(*names)
    enable_features(*names)
    save
  end

  def disable_features(*names)
    self.enabled_feature_keys = (enabled_feature_keys - names.map(&:to_s))
  end

  def disable_features!(*names)
    disable_features(*names)
    save
  end

  def all_features
    FEATURE_NAMES.index_with do |feature_name|
      feature_enabled?(feature_name)
    end
  end

  def enabled_features
    all_features.select { |_feature, enabled| enabled == true }
  end

  def disabled_features
    all_features.select { |_feature, enabled| enabled == false }
  end

  # Substitui o conjunto inteiro de uma vez (form builder do super admin). Replica o
  # selected_feature_flags= do FlagShihTzu: zera tudo e reabilita so as flags recebidas.
  # Aceita nomes com ou sem o prefixo "feature_" (o controller manda :feature_x); blank/nil ignorados.
  def selected_feature_flags=(flags)
    self.enabled_feature_keys = Array(flags).select(&:present?).map { |flag| flag.to_s.delete_prefix('feature_') }
  end

  # Leitura no mesmo formato do FlagShihTzu (simbolos :feature_x, na ordem do features.yml).
  def selected_feature_flags
    FEATURE_NAMES.select { |name| feature_enabled?(name) }.map { |name| :"feature_#{name}" }
  end

  private

  def enable_default_features
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return true if config.blank?

    features_to_enabled = config.value.select { |f| f[:enabled] }.pluck(:name)
    enable_features(*features_to_enabled)
  end
end
