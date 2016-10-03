class CommitStatus < ActiveRecord::Base
  include HasStatus
  include Importable

  self.table_name = 'ci_builds'

  belongs_to :project, class_name: '::Project', foreign_key: :gl_project_id
  belongs_to :pipeline, class_name: 'Ci::Pipeline', foreign_key: :commit_id
  belongs_to :user

  delegate :commit, to: :pipeline

  validates :pipeline, presence: true, unless: :importing?

  validates_presence_of :name

  alias_attribute :author, :user

  scope :latest, -> do
    max_id = unscope(:select).select("max(#{quoted_table_name}.id)")

    where(id: max_id.group(:name, :commit_id))
  end

  scope :retried, -> { where.not(id: latest) }
  scope :ordered, -> { order(:name) }
  scope :failed_but_allowed, -> do
    where(allow_failure: true, status: [:failed, :canceled])
  end
  scope :exclude_ignored, -> do
    quoted_when = connection.quote_column_name('when')
    where("allow_failure = ? OR status NOT IN (?)",
      false, [:failed, :canceled]).
      # We want to ignore skipped manual jobs
      where("#{quoted_when} <> ? OR status <> ?", 'manual', 'skipped').
      # We want to ignore skipped on_failure
      where("#{quoted_when} <> ? OR status <> ?", 'on_failure', 'skipped')

  end
  scope :latest_ci_stages, -> { latest.ordered.includes(project: :namespace) }
  scope :retried_ci_stages, -> { retried.ordered.includes(project: :namespace) }

  state_machine :status do
    event :enqueue do
      transition [:created, :skipped] => :pending
    end

    event :process do
      transition skipped: :created
    end

    event :run do
      transition pending: :running
    end

    event :skip do
      transition [:created, :pending] => :skipped
    end

    event :drop do
      transition [:created, :pending, :running] => :failed
    end

    event :success do
      transition [:created, :pending, :running] => :success
    end

    event :cancel do
      transition [:created, :pending, :running] => :canceled
    end

    after_transition created: [:pending, :running] do |commit_status|
      commit_status.update_attributes queued_at: Time.now
    end

    after_transition [:created, :pending] => :running do |commit_status|
      commit_status.update_attributes started_at: Time.now
    end

    after_transition any => [:success, :failed, :canceled] do |commit_status|
      commit_status.update_attributes finished_at: Time.now
    end

    after_transition any => [:success, :failed, :canceled] do |commit_status|
      commit_status.pipeline.try(:process!)
      true
    end

    after_transition do |commit_status, transition|
      commit_status.pipeline.try(:build_updated) unless transition.loopback?
    end

    after_transition [:created, :pending, :running] => :success do |commit_status|
      MergeRequests::MergeWhenBuildSucceedsService.new(commit_status.pipeline.project, nil).trigger(commit_status)
    end

    after_transition any => :failed do |commit_status|
      MergeRequests::AddTodoWhenBuildFailsService.new(commit_status.pipeline.project, nil).execute(commit_status)
    end
  end

  delegate :sha, :short_sha, to: :pipeline

  def before_sha
    pipeline.before_sha || Gitlab::Git::BLANK_SHA
  end

  def group_name
    name.gsub(/\d+[\s:\/\\]+\d+\s*/, '').strip
  end

  def self.stages
    # We group by stage name, but order stages by theirs' index
    unscoped.from(all, :sg).group('stage').order('max(stage_idx)', 'stage').pluck('sg.stage')
  end

  def self.stages_status
    # We execute subquery for each stage to calculate a stage status
    statuses = unscoped.from(all, :sg).group('stage').pluck('sg.stage', all.where('stage=sg.stage').status_sql)
    statuses.inject({}) do |h, k|
      h[k.first] = k.last
      h
    end
  end

  def failed_but_allowed?
    allow_failure? && (failed? || canceled?)
  end

  def playable?
    false
  end

  def duration
    calculate_duration
  end

  def stuck?
    false
  end
end
