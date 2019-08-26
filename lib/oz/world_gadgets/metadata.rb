require 'singleton'
require 'securerandom'
require 'date'
require 'psych'
require_relative '../world_gadgets/configuration_engine'

class Metadata
  include Singleton
  attr_accessor :content, :tags

  def set_base_data(world = nil)
    # TODO - Maintains current outward facing interface, once test frameworks use this way of grabbing the config
    # we can remove the lower line.
    @config = world.configuration if world
    @config ||= ConfigurationEngine.new
    @meta_config = meta_config
    @content ||= default_content
  end

  def meta_config
    file = Dir["#{ENV['OZ_CONFIG_DIR']}/metadata_config"]
    if file =~ /json/i
      JSON.parse(File.read(file))
    elsif file =~ /yaml|yml/i
      Psych.load_file(file)
    end
  end

  def default_content
    {
      framework: 'OZ',
      hostname: `hostname`.chomp,
      user: user,
      app_url: @config['ENVIRONMENT']['URL'],
      environment: @config['TEST_ENVIRONMENT'],
      config: @config,
      suite_run_id: ENV['SUITE_RUN_ID'] || "local_suite_#{SecureRandom.uuid}",
      pipeline_id: ENV['PIPELINE_ID'] || "local_pipeline_#{user}",
      branch: ENV['BRANCH'] || 'unknown',
      working_directory: Dir.pwd.split('/').last,
      retry: ENV['RETRY'] || false,
      retries: ENV['RETRIES]'] || 0
    }
  end

  def user
    if @world.configuration['ROOTDOMAIN']
      `whoami`.chomp.gsub("#{world.configuration['ROOTDOMAIN']}\\", '')
    else
      `whoami`.chomp
    end
  end

  def set_suite_start_time
    start_query = "suite_run_id:#{@content[:suite_run_id]} AND type:SUITE_START"
    begin
      result = SplunkEngine.instance.search start_query
      @content.merge!(suite_run_start: result['suite_run_start'])
    rescue
      @content.merge!(suite_run_start: eastern_time)
    end
  end

  def set_scenario_data(scenario, status = :pending)
    @tags = scenario.source_tag_names
    test_case_id = get_test_case
    json_tags = @tags.to_json
    @content.merge!(
      scenario_tags: @tags - [test_case_id],
      scenario_tags_search: json_tags,
      scenario_group: scenario_group,
      product: get_product,
      scenario_test_case: test_case_id,
      feature_name: scenario.feature.name,
      scenario_steps: get_step_text(scenario),
      scenario_name: scenario.name,
      scenario_status: status,
      scenario_run_id: SecureRandom.uuid,
      scenario_start_time: eastern_time,
      scenario_total_wait_time: 0
    )
  end

  def add_to_scenario_wait_time(time)
    @content.merge!(scenario_total_wait_time: (@content[:scenario_total_wait_time] + time).round(3))
  end

  def get_test_case
    @tags.find { |tag| tag.include?('test_case') }
  end

  def scenario_group
    @tags & @meta_config[:group_tags] || 'none'
  end

  def get_product
    result = @tags & @meta_config[:product_tags]
    result[0]&.gsub(/@/, '') || 'unknown'
  end

  def add_scenario_end_time
    @content.merge!(scenario_end_time: eastern_time)
  end

  def update_scenario_status(scenario)
    if (scenario.status == :failed) && (scenario.exception.message.include? '[ErrorPage]')
      @content[:scenario_status] = 'failed - Application Error'
    else
      @content[:scenario_status] = scenario.status
    end
    append_exception(scenario) if scenario.exception
  end

  def append_exception(scenario)
    @content[:message] = scenario.exception.to_s
    category = determine_category(scenario)
    @content[:exception] = sanitize_for_elk(scenario.exception.backtrace.join("\n"))
    @content[:category] = category[:category]
    @content[:broad_category] = category[:broad_category]
  end

  def append_ledger(ledger_hash)
    @content.merge!(ledger: ledger_hash.to_json)
  end

  def dst_start
    march_14th = Date.civil(Time.now.utc.to_date.year, 3, 14)
    march_14th - march_14th.wday
  end

  def dst_end
    november_7th = Date.civil(Time.now.utc.to_date.year, 11, 7)
    (november_7th - november_7th.wday) - 1
  end

  def currently_dst?
    (dst_start..dst_end).cover?(Time.now.utc.to_date)
  end

  def eastern_time
    dst = currently_dst? ? '-04:00' : '-05:00'
    Time.now.utc.getlocal(dst)
  end

  def add_scenario_end_time_and_duration
    scenario_start_time = @content[:scenario_start_time]
    scenario_end_time = eastern_time
    @content.merge!(scenario_end_time: scenario_end_time, scenario_duration: duration(scenario_start_time, scenario_end_time))
  end

  def add_suite_end_time_and_duration
    suite_start_time = @content[:suite_run_start]
    suite_end_time = eastern_time
    @content.merge!(suite_end_time: suite_end_time, suite_duration: duration(suite_start_time, suite_end_time)) if suite_start_time
  end

  def set_data_info(data_hash)
    @content.merge!(data_hash)
  end

  def set_data_type
    @content.merge!(data_info_type: information_record_type)
  end

  def append(metadata)
    @content ||= {}
    (@content.merge!(metadata) unless metadata.nil?)
  end

  def clear_metadata
    @content = {}
  end

  private

  def method_name(scenario)
    scenario.source_tag_names
  end

  def get_step_text(scenario)
    begin
      scenario.test_steps.map(&:source).map(&:last).map {|step_obj| step_obj.keyword + ' ' + step_obj.text}
    rescue
      scenario.test_steps.map(&:text)
    end
  end

  def duration(start_time, end_time)
    (end_time - start_time).round(2)
  end

  def information_record_type
    information_record_types = @meta_config['information_record_types']
    information_record_types.select { |key, _| @tags.include?(key) }.values ||
      "No Tag for scenario.  Should be #{information_record_types.keys}"
  end

  def determine_category(scenario)
    category = get_categories
    @result = category.find do |entry|
      @result = {}
      pattern = Regexp.new(entry['regex']).freeze
      {broad_category: entry['broad_category'], category: entry['category']} if pattern =~ scenario.exception.to_s
    end
    @content.merge!(broad_category: @result['broad_category'], category: @result['category'])
  end

  def get_categories
    root = YAML.load_file(File.join(__dir__, 'categories.yaml'))
    root.merge(YAML.load_file("#{}"))
  end

  def sanitize_for_elk(str)
    require 'shellwords'
    # this escapes strings for a bash shell which may have similar tokenizing reqs
    # this is a bit of overkill here but is a start until we know what Elasticsearch does not want
    Shellwords.escape(str)
  end
end