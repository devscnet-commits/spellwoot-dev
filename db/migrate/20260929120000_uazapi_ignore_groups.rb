# A IA nunca responde grupo: reaplica a integração UazAPI→Chatwoot com ignore_groups: true nas instâncias
# que já existiam (ver Migration::UazapiIgnoreGroupsJob).
class UazapiIgnoreGroups < ActiveRecord::Migration[7.1]
  def up
    Migration::UazapiIgnoreGroupsJob.perform_later
  end

  def down; end
end
