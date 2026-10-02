# Kanban data of a pipeline for the current user: one column per stage with the card count, the summed
# deal value and the first page of cards (most recent activity first). Filters: search (contact
# name/phone/e-mail or #id), temperature, sla=breached, assignee_id and status.
class Pipelines::BoardBuilder
  PER_PAGE = 20

  def initialize(flow:, user:, account:, params: {})
    @flow = flow
    @user = user
    @account = account
    @params = params
  end

  def columns
    stages = @flow.ordered_stages
    stats = { counts: scope.group(:pipeline_stage_id).count, values: column_values, automations: automation_counts(stages),
              ai_delays: ai_followup_delays(stages) }
    stages.map { |stage| column_for(stage, stats) }
  end

  def stage_cards(stage, page)
    page = [page.to_i, 1].max
    records = scope.where(pipeline_stage_id: stage.id)
                   .includes(:contact, :assignee, :team, :inbox)
                   .order(last_activity_at: :desc, id: :desc)
                   .offset((page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
    has_more = records.size > PER_PAGE
    records = records.first(PER_PAGE)
    { cards: Pipelines::CardPresenter.many(records, @flow), has_more: has_more }
  end

  def scope
    @scope ||= begin
      base = @account.conversations.where(pipeline_stage_id: @flow.resolution_states.select(:id))
      base = Conversations::PermissionFilterService.new(base, @user, @account).perform
      apply_filters(base)
    end
  end

  private

  def apply_filters(base)
    base = base.where(temperature: @params[:temperature]) if Conversation.temperatures.key?(@params[:temperature].to_s)
    base = base.where('conversations.pipeline_sla_due_at < ?', Time.current) if @params[:sla] == 'breached'
    base = base.where(assignee_id: @params[:assignee_id].presence) if @params.key?(:assignee_id)
    base = base.where(status: @params[:status]) if Conversation.statuses.key?(@params[:status].to_s)
    search(base)
  end

  def search(base)
    term = @params[:search].to_s.strip
    return base if term.blank?

    like = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
    matches = base.joins(:contact).where('contacts.name ILIKE :like OR contacts.phone_number ILIKE :like OR contacts.email ILIKE :like', like: like)
    display_id = term.delete('#')
    display_id.match?(/\A\d+\z/) ? matches.or(base.joins(:contact).where(display_id: display_id.to_i)) : matches
  end

  # ai_followup_delay: minutes of silence after which the stage's AI follow-up starts (the card shows
  # the "inativo" alert from there on).
  def column_for(stage, stats)
    { stage_id: stage.id, count: stats[:counts][stage.id].to_i, total_value: stats[:values][stage.id].to_f.round(2),
      automations_count: stats[:automations][[stage.id, 'automation']].to_i,
      ai_followups_count: stats[:automations][[stage.id, 'ai_followup']].to_i,
      ai_followup_delay: stats[:ai_delays][stage.id], **stage_cards(stage, 1) }
  end

  def ai_followup_delays(stages)
    PipelineAutomation.active.where(resolution_state_id: stages.map(&:id), kind: 'ai_followup').group(:resolution_state_id).minimum(:delay_minutes)
  end

  def automation_counts(stages)
    PipelineAutomation.active.where(resolution_state_id: stages.map(&:id)).group(:resolution_state_id, :kind).count
  end

  def column_values
    key = @flow.value_attribute_key
    return {} if key.blank?

    scope.pluck(:pipeline_stage_id, Arel.sql("conversations.custom_attributes ->> #{ActiveRecord::Base.connection.quote(key)}"))
         .each_with_object(Hash.new(0)) { |(stage_id, raw), sums| sums[stage_id] += OperationalFlow.parse_amount(raw) }
  end
end
