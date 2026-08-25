module Featurable
  extend ActiveSupport::Concern

  FEATURE_LIST = YAML.safe_load(Rails.root.join('config/features.yml').read).freeze
  FEATURE_NAMES = FEATURE_LIST.pluck('name').freeze

  included do
    before_create :enable_default_features

    FEATURE_NAMES.each do |feature_name|
      define_method("feature_#{feature_name}?") { feature_enabled?(feature_name) }

      define_method("feature_#{feature_name}=") do |value|
        ActiveModel::Type::Boolean.new.cast(value) ? enable_features(feature_name) : disable_features(feature_name)
      end

      scope "feature_#{feature_name}", -> { where('enabled_feature_keys @> ARRAY[?]::varchar[]', feature_name) }
      scope "not_feature_#{feature_name}", -> { where.not('enabled_feature_keys @> ARRAY[?]::varchar[]', feature_name) }
    end
  end

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

  def selected_feature_flags=(flags)
    self.enabled_feature_keys = Array(flags).select(&:present?).map { |flag| flag.to_s.delete_prefix('feature_') }
  end

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
