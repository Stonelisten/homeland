class TopicsController < ApplicationController
  before_action :authenticate_user!, only: [:new, :edit, :create, :update, :destroy,
                                            :favorite, :unfavorite, :follow, :unfollow,
                                            :action, :favorites]
  load_and_authorize_resource only: [:new, :edit, :create, :update, :destroy,
                                     :favorite, :unfavorite, :follow, :unfollow]

  before_action :set_topic, only: [:ban, :edit, :update, :destroy, :follow,
                                   :unfollow, :action]

  def index
    @suggest_topics = []
    if params[:page].to_i <= 1
      @suggest_topics = Topic.without_hide_nodes.suggest.fields_for_list.limit(3)
    end
    @topics = Topic.last_actived.without_suggest
    @topics =
      if current_user
        @topics.without_nodes(current_user.block_node_ids)
               .without_users(current_user.block_user_ids)
      else
        @topics.without_hide_nodes
      end
    @topics = @topics.fields_for_list
    @topics = @topics.page(params[:page])
    @page_title = t('menu.topics')
    @read_topic_ids = []
    if current_user
      @read_topic_ids = current_user.filter_readed_topics(@topics + @suggest_topics)
    end
    fresh_when([@suggest_topics, @topics, @read_topic_ids])
  end

  def feed
    @topics = Topic.without_hide_nodes.recent.limit(20).includes(:node, :user, :last_reply_user)
    render layout: false if stale?(@topics)
  end

  def node
    @node = Node.find(params[:id])
    @topics = @node.topics.last_actived.fields_for_list
    @topics = @topics.includes(:user).page(params[:page])
    @page_title = "#{@node.name} &raquo; #{t('menu.topics')}"
    @page_title = [@node.name, t('menu.topics')].join(' · ')
    if stale?(etag: [@node, @topics], template: 'topics/index')
      render action: 'index'
    end
  end

  def node_feed
    @node = Node.find(params[:id])
    @topics = @node.topics.recent.limit(20)
    render layout: false if stale?([@node, @topics])
  end

  %w(no_reply popular).each do |name|
    define_method(name) do
      @topics = Topic.without_hide_nodes.send(name.to_sym).last_actived.fields_for_list.includes(:user)
      @topics = @topics.page(params[:page])

      @page_title = [t("topics.topic_list.#{name}"), t('menu.topics')].join(' · ')
      render action: 'index' if stale?(etag: @topics, template: 'topics/index')
    end
  end

  # GET /topics/favorites
  def favorites
    @topics = current_user.favorite_topics.includes(:user).fields_for_list
    @topics = @topics.page(params[:page])
    render action: 'index' if stale?(etag: @topics, template: 'topics/index')
  end

  def recent
    @topics = Topic.without_hide_nodes.recent.fields_for_list.includes(:user)
    @topics = @topics.page(params[:page])
    @page_title = [t('topics.topic_list.recent'), t('menu.topics')].join(' · ')
    render action: 'index' if stale?(etag: @topics, template: 'topics/index')
  end

  def excellent
    @topics = Topic.excellent.recent.fields_for_list.includes(:user)
    @topics = @topics.page(params[:page])

    @page_title = [t('topics.topic_list.excellent'), t('menu.topics')].join(' · ')
    render action: 'index' if stale?(etag: @topics, template: 'topics/index')
  end

  def show
    @topic = Topic.unscoped.includes(:user).find(params[:id])
    render_404 if @topic.deleted?

    @topic.hits.incr(1)
    @node = @topic.node
    @show_raw = params[:raw] == '1'
    @can_reply = can? :create, Reply

    @replies = Reply.unscoped.where(topic_id: @topic.id).order(:id).all
    @user_like_reply_ids = current_user&.like_reply_ids_by_replies(@replies) || []

    check_current_user_status_for_topic
    set_special_node_active_menu
    fresh_when([@topic, @node, @show_raw, @replies, @user_like_reply_ids, @has_followed, @has_favorited, @can_reply])
  end

  def new
    @topic = Topic.new(user_id: current_user.id)
    unless params[:node].blank?
      @topic.node_id = params[:node]
      @node = Node.find_by_id(params[:node])
      render_404 if @node.blank?
    end
  end

  def edit
    @node = @topic.node
  end

  def create
    @topic = Topic.new(topic_params)
    @topic.user_id = current_user.id
    @topic.node_id = params[:node] || topic_params[:node_id]
    @topic.team_id = ability_team_id
    @topic.save
  end

  def preview
    @body = params[:body]

    respond_to do |format|
      format.json
    end
  end

  def update
    @topic.admin_editing = true if current_user.admin?

    if can?(:change_node, @topic)
      # 锁定接点的时候，只有管理员可以修改节点
      @topic.node_id = topic_params[:node_id]

      if current_user.admin? && @topic.node_id_changed?
        # 当管理员修改节点的时候，锁定节点
        @topic.lock_node = true
      end
    end
    @topic.team_id = ability_team_id
    @topic.title = topic_params[:title]
    @topic.body = topic_params[:body]
    @topic.save
  end

  def destroy
    @topic.destroy_by(current_user)
    redirect_to(topics_path, notice: t('topics.delete_topic_success'))
  end

  def favorite
    current_user.favorite_topic(params[:id])
    render plain: '1'
  end

  def unfavorite
    current_user.unfavorite_topic(params[:id])
    render plain: '1'
  end

  def follow
    current_user.follow_topic(@topic)
    render plain: '1'
  end

  def unfollow
    current_user.unfollow_topic(@topic)
    render plain: '1'
  end

  def action
    authorize! params[:type].to_sym, @topic

    case params[:type]
    when 'excellent'
      @topic.excellent!
      redirect_to @topic, notice: '加精成功。'
    when 'unexcellent'
      @topic.unexcellent!
      redirect_to @topic, notice: '加精已经取消。'
    when 'ban'
      @topic.ban!
      redirect_to @topic, notice: '已转移到 NoPoint 节点。'
    when 'close'
      @topic.close!
      redirect_to @topic, notice: '话题已关闭，将不再接受任何新的回复。'
    when 'open'
      @topic.open!
      redirect_to @topic, notice: '话题已重启开启。'
    end
  end

  private

  def set_topic
    @topic ||= Topic.find(params[:id])
  end

  def topic_params
    params.require(:topic).permit(:title, :body, :node_id, :team_id)
  end

  def ability_team_id
    team = Team.find_by_id(topic_params[:team_id])
    return nil if team.blank?
    return nil if cannot?(:show, team)
    team.id
  end

  def check_current_user_status_for_topic
    return false unless current_user
    # 通知处理
    current_user.read_topic(@topic, replies_ids: @replies.collect(&:id))
    # 是否关注过
    @has_followed = current_user.follow_topic?(@topic)
    # 是否收藏
    @has_favorited = current_user.favorite_topic?(@topic)
  end

  def set_special_node_active_menu
    if Setting.has_module?(:jobs)
      # FIXME: Monkey Patch for homeland-jobs
      if @node&.id == 25
        @current = ['/jobs']
      end
    end
  end
end
