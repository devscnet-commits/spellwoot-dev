# Os planos comerciais nasceram em produção com slugs que o código nunca conheceu (`pro`, `standard`).
# Consequências que já apareceram: plans:seed nunca os configurou (ficaram sem nenhuma PlanFeature, e
# por isso contas nesses planos não liberavam chave própria de IA), e Plan::COMMERCIAL_RANK não os
# lista, então Plan::ChangeSubscriptionService#upgrade! levanta 'Plano atual não permite troca
# automática' para qualquer conta neles.
#
# Alinha os slugs ao catálogo da tabela Planos_Conexi_v2: standard -> plus, pro -> pro_plus.
# Renomear é seguro: nada guarda slug de plano fora da tabela `plans` (COMMERCIAL_RANK e o seed são
# código; o endpoint de upgrade e o front recebem o slug da API, então acompanham sozinhos).
class RenamePlanSlugsToV2Catalog < ActiveRecord::Migration[7.1]
  RENAMES = { 'standard' => 'plus', 'pro' => 'pro_plus' }.freeze

  def up
    apply(RENAMES)
  end

  def down
    apply(RENAMES.invert)
  end

  private

  # Idempotente e não-destrutiva: se o slug de destino já existir (seed rodado antes desta migration),
  # não força — o índice único recusaria, e sobrescrever silenciosamente perderia um plano.
  def apply(mapping)
    mapping.each do |from, to|
      origem = Plan.find_by(slug: from)
      next if origem.blank?

      if Plan.exists?(slug: to)
        say "plano '#{to}' já existe — '#{from}' mantido; resolva manualmente qual dos dois fica"
        next
      end

      origem.update_columns(slug: to) # rubocop:disable Rails/SkipsModelValidations
      say "plano '#{from}' renomeado para '#{to}'"
    end
  end
end
