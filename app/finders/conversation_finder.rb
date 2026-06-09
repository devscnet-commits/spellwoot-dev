class ConversationFinder
  attr_reader :current_user, :current_account, :params

  DEFAULT_STATUS = 'open'.freeze
  SORT_OPTIONS = {
    'last_activity_at_asc' => %w[sort_on_last_activity_at asc],
    'last_activity_at_desc' => %w[sort_on_last_activity_at desc],
    'created_at_asc' => %w[sort_on_created_at asc],
    'created_at_desc' => %w[sort_on_created_at desc],
    'priority_asc' => %w[sort_on_priority asc],
    'priority_desc' => %w[sort_on_priority desc],
    'waiting_since_asc' => %w[sort_on_waiting_since asc],
    'waiting_since_desc' => %w[sort_on_waiting_since desc],
    'priority_desc_created_at_asc' => %w[sort_on_priority_created_at desc],

    # To be removed in v3.5.0
    'latest' => %w[sort_on_last_activity_at desc],
    'sort_on_created_at' => %w[sort_on_created_at asc],
    'sort_on_priority' => %w[sort_on_priority desc],
    'sort_on_waiting_since' => %w[sort_on_waiting_since asc]
  }.with_indifferent_access
  # assumptions
  # inbox_id if not given, take from all conversations, else specific to inbox
  # assignee_type if not given, take 'all'
  # conversation_status if not given, take 'open'

  # response of this class will be of type
  # {conversations: [array of conversations], count: {open: count, resolved: count}}

  # params
  # assignee_type, inbox_id, :status

  def initialize(current_user, params)
    @current_user = current_user
    @current_account = current_user.account
    @is_admin = current_account.account_users.find_by(user_id: current_user.id)&.administrator?
    @params = params
  end

  def perform
    set_up
    filter_by_assignee_type

    {
      conversations: conversations,
      count: tab_counts
    }
  end

  def perform_meta_only
    set_up

    { count: tab_counts }
  end

  private

  def set_up
    set_inboxes
    set_team
    set_assignee_type

    find_all_conversations
    filter_by_team
    filter_by_labels
    filter_by_query
    filter_by_source_id
    filter_by_reopened
    filter_by_campaign_id

    # Snapshot the fully-scoped set BEFORE applying the status filter. Tab counters are
    # derived from this so they stay stable — open mine/unassigned/all plus a resolved
    # total — no matter which status the list itself is currently showing.
    @scoped_conversations = @conversations
    filter_by_status unless params[:q]
  end

  def filter_by_reopened
    return unless params[:was_reopened].to_s == 'true'

    @conversations = @conversations.where("additional_attributes->>'was_reopened' = 'true'")
  end

  def set_inboxes
    @inbox_ids = if params[:inbox_id]
                   @current_user.assigned_inboxes.where(id: params[:inbox_id])
                 else
                   @current_user.assigned_inboxes.pluck(:id)
                 end
  end

  def set_assignee_type
    @assignee_type = params[:assignee_type]
  end

  def set_team
    @team = current_account.teams.find(params[:team_id]) if params[:team_id]
  end

  def find_conversation_by_inbox
    @conversations = current_account.conversations

    return unless params[:inbox_id]

    @conversations = @conversations.where(inbox_id: @inbox_ids)
  end

  def find_all_conversations
    find_conversation_by_inbox
    # Apply permission-based filtering
    @conversations = Conversations::PermissionFilterService.new(
      @conversations,
      current_user,
      current_account
    ).perform
    filter_by_conversation_type if params[:conversation_type]
    @conversations
  end

  def filter_by_assignee_type
    case @assignee_type
    when 'me'
      @conversations = @conversations.assigned_to(current_user)
    when 'unassigned'
      @conversations = @conversations.unassigned
    when 'assigned'
      @conversations = @conversations.assigned
    end
    @conversations
  end

  def filter_by_conversation_type
    case @params[:conversation_type]
    when 'mention'
      conversation_ids = current_account.mentions.where(user: current_user).pluck(:conversation_id)
      @conversations = @conversations.where(id: conversation_ids)
    when 'participating'
      @conversations = current_user.participating_conversations.where(account_id: current_account.id)
    when 'unattended'
      @conversations = @conversations.unattended
    end
    @conversations
  end

  def filter_by_query
    return unless params[:q]

    allowed_message_types = [Message.message_types[:incoming], Message.message_types[:outgoing]]
    @conversations = conversations.joins(:messages).where('messages.content ILIKE :search', search: "%#{params[:q]}%")
                                  .where(messages: { message_type: allowed_message_types }).includes(:messages)
                                  .where('messages.content ILIKE :search', search: "%#{params[:q]}%")
                                  .where(messages: { message_type: allowed_message_types })
  end

  def filter_by_status
    return if params[:status] == 'all'

    @conversations = @conversations.where(status: params[:status] || DEFAULT_STATUS)
  end

  def filter_by_team
    return unless @team

    @conversations = @conversations.where(team: @team)
  end

  def filter_by_labels
    return unless params[:labels]

    @conversations = @conversations.tagged_with(params[:labels], any: true)
  end

  def filter_by_source_id
    return unless params[:source_id]

    @conversations = @conversations.joins(:contact_inbox)
    @conversations = @conversations.where(contact_inboxes: { source_id: params[:source_id] })
  end

  def filter_by_campaign_id
    return unless params[:campaign_id]

    @conversations = @conversations.where(campaign_id: params[:campaign_id])
  end

  # Stable tab counters. The open assignee tabs always count open conversations; the
  # resolved tab always gets the resolved total — independent of the active status/tab.
  def tab_counts
    open_scope = @scoped_conversations.where(status: :open)
    unassigned_count = open_scope.unassigned.count
    all_count = open_scope.count

    {
      mine_count: open_scope.assigned_to(current_user).count,
      assigned_count: all_count - unassigned_count,
      unassigned_count: unassigned_count,
      all_count: all_count,
      resolved_count: @scoped_conversations.where(status: :resolved).count
    }
  end

  def current_page
    params[:page] || 1
  end

  def conversations_base_query
    @conversations.includes(
      :taggings, :inbox, { assignee: { avatar_attachment: [:blob] } }, { contact: { avatar_attachment: [:blob] } }, :team, :contact_inbox
    )
  end

  def conversations
    @conversations = conversations_base_query

    sort_by, sort_order = SORT_OPTIONS[params[:sort_by]] || SORT_OPTIONS['last_activity_at_desc']
    @conversations = @conversations.send(sort_by, sort_order)

    if params[:updated_within].present?
      @conversations.where('conversations.updated_at > ?', Time.zone.now - params[:updated_within].to_i.seconds)
    else
      @conversations.page(current_page).per(ENV.fetch('CONVERSATION_RESULTS_PER_PAGE', '25').to_i)
    end
  end
end
ConversationFinder.prepend_mod_with('ConversationFinder')
