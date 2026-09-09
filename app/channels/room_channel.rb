class RoomChannel < ApplicationCable::Channel
  def subscribed
    # TODO: should we only do ensure stream  if current account is present?
    # for now going ahead with guard clauses in update_subscription and broadcast_presence
    current_user
    current_account
    ensure_stream
    update_subscription
    broadcast_presence
    trigger_pending_assignments
  end

  def update_presence
    update_subscription
    broadcast_presence
  end

  private

  def broadcast_presence
    return if @current_account.blank?

    data = { account_id: @current_account.id, users: ::OnlineStatusTracker.get_available_users(@current_account.id) }
    data[:contacts] = ::OnlineStatusTracker.get_available_contacts(@current_account.id) if @current_user.is_a? User
    ActionCable.server.broadcast(pubsub_token, { event: 'presence.update', data: data })
  end

  def ensure_stream
    stream_from pubsub_token
    stream_from "account_#{@current_account.id}" if @current_account.present? && @current_user.is_a?(User)
  end

  def update_subscription
    return if @current_account.blank?

    ::OnlineStatusTracker.update_presence(@current_account.id, @current_user.class.name, @current_user.id)
  end

  # An agent connecting (login, tab reopen, reconnect) can leave conversations that arrived while
  # everyone was offline/out of office waiting up to 30 minutes for AutoAssignment::PeriodicAssignmentJob
  # to notice. Nudge assignment for that agent's own inboxes right away instead of waiting on the timer.
  # Runs once per connection (subscribed), not on every presence heartbeat (update_presence).
  def trigger_pending_assignments
    return unless @current_user.is_a?(User)

    @current_user.inboxes.where(account_id: @current_account.id, enable_auto_assignment: true).find_each do |inbox|
      AutoAssignment::AssignmentJob.perform_later(inbox_id: inbox.id) if inbox.auto_assignment_v2_enabled?
    end
  end

  def pubsub_token
    @pubsub_token ||= params[:pubsub_token]
  end

  def current_user
    @current_user ||= if params[:user_id].blank?
                        ContactInbox.find_by!(pubsub_token: pubsub_token).contact
                      else
                        User.find_by!(pubsub_token: pubsub_token, id: params[:user_id])
                      end
  end

  def current_account
    return if current_user.blank?

    @current_account ||= if @current_user.is_a? Contact
                           @current_user.account
                         else
                           @current_user.accounts.find(params[:account_id])
                         end
  end
end
