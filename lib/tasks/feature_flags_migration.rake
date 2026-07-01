# Passo 2 da migração de feature flags: bit-packed (feature_flags bigint, teto de 63) ->
# lista de chaves (enabled_feature_keys text[]). Estas tasks NÃO mudam comportamento — o concern
# ainda lê pelos bits (autoritativo). Só copiam a verdade atual para o array e conferem paridade.
#
#   rails feature_flags:backfill   # popula enabled_feature_keys a partir dos bits (idempotente)
#   rails feature_flags:verify     # confere que bits e array batem em toda conta (aborta se divergir)
#
# Rodar o backfill imediatamente ANTES do deploy do Passo 3 (troca do concern) e verificar em
# seguida — fecha a janela sem dual-write. Ver [[feature-flags-63-limit]].
namespace :feature_flags do
  desc 'Passo 2: backfill de enabled_feature_keys a partir dos bits atuais (idempotente)'
  task backfill: :environment do
    total = 0
    Account.find_each do |account|
      # enabled_features (metodo do concern) le pelos BITS (verdade atual); .keys = features ligadas.
      # update_column grava direto no array: sem validacao, callback nem updated_at, e nao toca
      # feature_flags (os bits seguem autoritativos ate o Passo 3).
      account.update_column(:enabled_feature_keys, account.enabled_features.keys)
      total += 1
    end
    puts "[feature_flags:backfill] #{total} conta(s) atualizada(s)."
  end

  desc 'Passo 2: verifica que bits e array batem em toda conta (read-only; aborta se divergir)'
  task verify: :environment do
    checked = 0
    mismatches = 0
    Account.find_each do |account|
      checked += 1
      from_bits  = account.enabled_features.keys.sort      # verdade dos bits
      from_array = account.enabled_feature_keys.to_a.sort   # o que o backfill gravou
      next if from_bits == from_array

      mismatches += 1
      warn "[feature_flags:verify] DIVERGENCIA account=#{account.id} " \
           "so_nos_bits=#{(from_bits - from_array).inspect} " \
           "so_no_array=#{(from_array - from_bits).inspect}"
    end
    puts "[feature_flags:verify] verificadas=#{checked} divergencias=#{mismatches}"
    abort('DIVERGENCIAS ENCONTRADAS — NAO prossiga para o Passo 3') if mismatches.positive?
  end
end
