# Pipeline (CRM kanban) report for a period, built from the stage moves (ConversationStageEvent):
#   summary   new cards, won/lost (count and deal value), win rate, average cycle, open pipeline now
#   stages    cards and value in each column now, cards that entered it and average time spent in it
#   funnel    of the cards that entered the pipeline in the period, how many reached each open stage
#             and the won column (conversion from the first stage)
#   losses    from which stage the lost cards were lost
#   agents    won/lost/open per card owner
#   daily     new / won / lost per day
# Cards are limited to the conversations the user can see.
class Pipelines::ReportBuilder
  DEFAULT_RANGE = 30.days
  MAX_RANGE = 366.days

  def initialize(flow:, user:, account:, since: nil, upto: nil)
    @flow = flow
    @user = user
    @account = account
    @until = parse_time(upto) || Time.current
    @since = [parse_time(since) || (@until - DEFAULT_RANGE), @until - MAX_RANGE].max
  end

  def perform
    {
      range: { since: @since.to_i, until: @until.to_i },
      summary: summary, stages: stage_rows, funnel: funnel, losses: losses, agents: agents, daily: daily
    }
  end

  private

  def parse_time(value)
    return if value.blank?

    value.to_s.match?(/\A\d+\z/) ? Time.zone.at(value.to_i) : Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def stages
    @stages ||= @flow.ordered_stages
  end

  def stage_by_id
    @stage_by_id ||= stages.index_by(&:id)
  end

  def open_stages
    stages.select(&:stage?)
  end

  def won_ids = stages.select { |stage| stage.polarity == 'positive' }.map(&:id)

  def lost_ids = stages.select { |stage| stage.polarity == 'negative' }.map(&:id)

  def visible_conversations
    @visible_conversations ||= Conversations::PermissionFilterService.new(@account.conversations, @user, @account).perform
  end

  # Every stage move of the visible cards of this pipeline, oldest first.
  def events
    @events ||= ConversationStageEvent.where(operational_flow_id: @flow.id, conversation_id: visible_conversations.select(:id))
                                      .order(:created_at, :id).pluck(:conversation_id, :from_stage_id, :to_stage_id, :created_at)
                                      .map { |conversation_id, from, to, at| { conversation_id: conversation_id, from: from, to: to, at: at } }
  end

  def events_in_period
    @events_in_period ||= events.select { |event| event[:at].between?(@since, @until) }
  end

  def events_by_conversation
    @events_by_conversation ||= events.group_by { |event| event[:conversation_id] }
  end

  def conversations
    @conversations ||= visible_conversations.where(id: events.pluck(:conversation_id).uniq)
                                            .includes(:assignee).index_by(&:id)
  end

  def value_of(conversation_id)
    conversation = conversations[conversation_id]
    conversation ? @flow.deal_value(conversation) : 0
  end

  # First time each card entered this pipeline (coming from nowhere or from another pipeline).
  def entries
    @entries ||= events_by_conversation.transform_values do |list|
      list.find { |event| event[:from].nil? || !stage_by_id.key?(event[:from]) }&.dig(:at)
    end.compact
  end

  def cohort_ids
    @cohort_ids ||= entries.select { |_id, at| at.between?(@since, @until) }.keys
  end

  def closed_in_period(stage_ids)
    events_in_period.select { |event| stage_ids.include?(event[:to]) }.uniq { |event| event[:conversation_id] }
  end

  def won_events
    @won_events ||= closed_in_period(won_ids)
  end

  def lost_events
    @lost_events ||= closed_in_period(lost_ids)
  end

  def summary
    won = won_events.pluck(:conversation_id)
    lost = lost_events.pluck(:conversation_id)
    {
      new_cards: cohort_ids.size, won_count: won.size, won_value: sum_values(won), lost_count: lost.size,
      lost_value: sum_values(lost), win_rate: percentage(won.size, won.size + lost.size), avg_cycle_seconds: average_cycle,
      open_count: open_card_ids.size, open_value: sum_current_values(open_card_ids)
    }
  end

  def percentage(part, total)
    total.zero? ? nil : (part * 100.0 / total).round(1)
  end

  def average(values)
    values.empty? ? nil : (values.sum / values.size).round
  end

  # From entering the pipeline to being won.
  def average_cycle
    average(won_events.filter_map { |event| (entry = entries[event[:conversation_id]]) && (event[:at] - entry) })
  end

  def sum_values(conversation_ids)
    conversation_ids.sum { |id| value_of(id) }.round(2)
  end

  # Where each visible card of the pipeline is now: { conversation_id => stage_id }.
  def current_cards
    @current_cards ||= visible_conversations.where(pipeline_stage_id: stages.map(&:id)).pluck(:id, :pipeline_stage_id).to_h
  end

  def open_card_ids
    @open_card_ids ||= current_cards.select { |_id, stage_id| stage_by_id[stage_id]&.stage? }.keys
  end

  def current_values
    @current_values ||= visible_conversations.where(id: current_cards.keys).includes(:assignee).index_by(&:id)
  end

  def sum_current_values(ids)
    ids.sum { |id| current_values[id] ? @flow.deal_value(current_values[id]) : 0 }.round(2)
  end

  def stage_info(stage)
    { stage_id: stage.id, name: stage.display_label, polarity: stage.polarity, color: stage.color }
  end

  def stage_rows
    durations = stage_durations
    stages.map do |stage|
      ids = current_cards.select { |_id, stage_id| stage_id == stage.id }.keys
      stage_info(stage).merge(count: ids.size, value: sum_current_values(ids), avg_time_seconds: average(durations[stage.id]),
                              entered: events_in_period.count { |event| event[:to] == stage.id })
    end
  end

  # Time spent in each stage, for the stays that ended inside the period.
  def stage_durations
    events_by_conversation.values.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |list, durations|
      list.each_cons(2) do |current, following|
        next unless following[:at].between?(@since, @until) && stage_by_id.key?(current[:to])

        durations[current[:to]] << (following[:at] - current[:at])
      end
    end
  end

  # Of the cards that entered in the period, how many reached each open stage (by position) or the
  # won column — reaching won counts as having gone through every open stage.
  def funnel
    reached = cohort_ids.filter_map { |id| furthest_position(events_by_conversation[id]) }
    funnel_steps.map do |stage, position|
      count = reached.count { |value| value >= position }
      stage_info(stage).merge(count: count, conversion: percentage(count, reached.size))
    end
  end

  def funnel_steps
    steps = open_stages.each_with_index.to_a
    won_stage = stages.find { |stage| won_ids.include?(stage.id) }
    won_stage ? steps << [won_stage, open_stages.size] : steps
  end

  def furthest_position(list)
    positions = open_stages.each_with_index.to_h { |stage, index| [stage.id, index] }
    list.filter_map { |event| won_ids.include?(event[:to]) ? open_stages.size : positions[event[:to]] }.max
  end

  def losses
    rows = lost_events.group_by { |event| event[:from] }.map do |from, list|
      { stage_id: from, name: stage_by_id[from]&.display_label, count: list.size, value: sum_values(list.pluck(:conversation_id)) }
    end
    rows.sort_by { |row| -row[:count] }
  end

  def agents
    rows = Hash.new { |hash, key| hash[key] = { won_count: 0, won_value: 0.0, lost_count: 0, open_count: 0 } }
    won_events.each { |event| tally(rows, conversations[event[:conversation_id]], :won_count, value_of(event[:conversation_id])) }
    lost_events.each { |event| tally(rows, conversations[event[:conversation_id]], :lost_count) }
    open_card_ids.each { |id| tally(rows, current_values[id], :open_count) }
    agent_rows(rows)
  end

  def tally(rows, conversation, counter, value = nil)
    assignee = conversation&.assignee
    row = rows[[assignee&.id, assignee&.name]]
    row[counter] += 1
    row[:won_value] += value if value
  end

  def agent_rows(rows)
    rows = rows.map { |(id, name), data| data.merge(user_id: id, name: name, won_value: data[:won_value].round(2)) }
    rows.sort_by { |row| [-row[:won_value], -row[:won_count]] }
  end

  def daily
    days = (@since.to_date..@until.to_date).index_with { { new_cards: 0, won: 0, lost: 0 } }
    count_days(days, entries.values, :new_cards)
    count_days(days, won_events.pluck(:at), :won)
    count_days(days, lost_events.pluck(:at), :lost)
    days.map { |date, data| data.merge(date: date.iso8601) }
  end

  def count_days(days, times, counter)
    times.each { |at| days[at.to_date][counter] += 1 if days.key?(at.to_date) }
  end
end
