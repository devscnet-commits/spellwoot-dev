# READ-ONLY: baseline de custo/tokens da IA a partir de Ai::Run. NENHUMA escrita — só SELECT agregado.
# Ninguém consulta esses dados hoje; a task gera o baseline ANTES de qualquer otimização de custo.
#
#   bundle exec rails "ai:cost_report"       # últimos 7 dias (default)
#   bundle exec rails "ai:cost_report[30]"   # últimos 30 dias
#
# No Coolify (container Rails), qualquer uma das opções:
#   bundle exec rake "ai:cost_report[7]"
#   bundle exec rails runner 'Rails.application.load_tasks; Rake::Task["ai:cost_report"].invoke("7")'
class AiCostReport
  DEFAULT_DAYS = 7
  WIDTH = 72

  def initialize(days = DEFAULT_DAYS)
    parsed = days.to_i
    @days = parsed.positive? ? parsed : DEFAULT_DAYS
    @scope = Ai::Run.where(created_at: @days.days.ago..)
  end

  # Imprime todas as seções (a..e). Retorna nil — nada aqui escreve no banco.
  def print
    header
    by_run_type
    by_account
    per_conversation
    status_rates
    cached_tokens_section
    nil
  end

  private

  attr_reader :scope, :days

  def header
    puts '=' * WIDTH
    puts "BASELINE DE CUSTO IA — últimos #{days} dia(s) (gerado #{Time.current.utc.iso8601})"
    puts "Total de runs no período: #{scope.count}"
    puts '=' * WIDTH
  end

  # a) custo total, tokens e contagem por run_type (decision/capture_judge/shadow_eval/followup/...).
  def by_run_type
    section('a) Custo e tokens por run_type')
    rows = scope.group(:run_type).order(Arel.sql('SUM(cost) DESC'))
                .pluck(:run_type, Arel.sql('COUNT(*)'), Arel.sql('COALESCE(SUM(cost), 0)'),
                       Arel.sql('COALESCE(SUM(tokens_in), 0)'), Arel.sql('COALESCE(SUM(tokens_out), 0)'))
    return puts('  (sem runs)') if rows.empty?

    rows.each { |type, n, cost, ti, to| puts run_type_line(type, n, cost, ti, to) }
  end

  def run_type_line(type, count, cost, tokens_in, tokens_out)
    "  #{label(type)} runs=#{count.to_s.ljust(7)} cost=$#{money(cost)} " \
      "tok_in=#{tokens_in.to_i} tok_out=#{tokens_out.to_i}"
  end

  # b) custo por conta (top 10 por custo).
  def by_account
    section('b) Custo por conta (top 10)')
    rows = scope.group(:account_id).order(Arel.sql('SUM(cost) DESC')).limit(10)
                .pluck(:account_id, Arel.sql('COUNT(*)'), Arel.sql('COALESCE(SUM(cost), 0)'))
    return puts('  (sem runs)') if rows.empty?

    rows.each do |account_id, n, cost|
      puts "  account=#{account_id.to_s.ljust(8)} runs=#{n.to_s.ljust(7)} cost=$#{money(cost)}"
    end
  end

  # c) custo/tokens_in médios por CONVERSA (agrupando por conversation_id) e por TURNO (por run).
  def per_conversation
    section('c) Médias por conversa e por turno')
    turns = scope.count
    convos = scope.where.not(conversation_id: nil).distinct.count(:conversation_id)
    cost = scope.sum(:cost).to_f
    tokens_in = scope.sum(:tokens_in).to_i
    puts "  conversas distintas=#{convos} | turnos (runs)=#{turns}"
    puts "  POR CONVERSA  cost médio=$#{money(safe_div(cost, convos))} " \
         "tokens_in médio=#{safe_div(tokens_in, convos).round(1)}"
    puts "  POR TURNO     cost médio=$#{money(safe_div(cost, turns))} " \
         "tokens_in médio=#{safe_div(tokens_in, turns).round(1)}"
  end

  # d) taxa de status (recorded vs error) por run_type.
  def status_rates
    section('d) Taxa de status (recorded vs error) por run_type')
    counts = scope.group(:run_type, :status).count
    types = counts.keys.map(&:first).uniq.sort
    return puts('  (sem runs)') if types.empty?

    types.each { |type| puts status_line(type, counts) }
  end

  def status_line(type, counts)
    recorded = counts[[type, 'recorded']].to_i
    error = counts[[type, 'error']].to_i
    total = counts.sum { |(t, _s), n| t == type ? n : 0 }
    "  #{label(type)} total=#{total.to_s.ljust(7)} " \
      "recorded=#{recorded} (#{pct(recorded, total)}%) error=#{error} (#{pct(error, total)}%)"
  end

  # e) cached_tokens (só se a coluna existir): soma e % de runs com cache > 0.
  def cached_tokens_section
    section('e) cached_tokens')
    return puts('  (coluna cached_tokens não existe nesta instalação)') unless cached_column?

    turns = scope.count
    with_cache = scope.where('cached_tokens > 0').count
    total_cached = scope.where.not(cached_tokens: nil).sum(:cached_tokens).to_i
    puts "  soma cached_tokens=#{total_cached} | runs com cache>0: " \
         "#{with_cache} de #{turns} (#{pct(with_cache, turns)}%)"
  end

  def cached_column?
    Ai::Run.column_names.include?('cached_tokens')
  end

  def section(title)
    puts
    puts title
    puts '-' * WIDTH
  end

  def label(type)
    type.to_s.ljust(16)
  end

  def money(value)
    value.to_f.round(6)
  end

  def safe_div(num, den)
    den.to_i.zero? ? 0.0 : num.to_f / den.to_i
  end

  def pct(part, total)
    total.to_i.zero? ? 0.0 : (part.to_f / total.to_i * 100).round(1)
  end
end

namespace :ai do
  desc 'READ-ONLY: baseline de custo/tokens da IA por período (dias, default 7) a partir de Ai::Run'
  task :cost_report, %i[days] => :environment do |_t, args|
    AiCostReport.new(args[:days] || AiCostReport::DEFAULT_DAYS).print
  end
end
