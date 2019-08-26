require 'net/http'
require 'singleton'
require 'yaml'
require 'open-uri'
require 'securerandom'
require_relative 'configuration_engine'

class KibanaEngine
  include Singleton

  attr_accessor :kibana_index, :world

  def initialize(world, kibana_index = 'oztests')
    @kibana_index = kibana_index
    @config = world.config
  end

  def kibana_base_url
    host = @config['KIBANA_URL']
    port = @config['KIBANA_PORT']
    "#{host}:#{port}"
  end

  def kibana_url
    "#{kibana_base_url}/#{@kibana_index}"
  end

  def retrieve_entry_from_kibana(query)
    response = kibana_query(query)
    result = response.dig('hits', 'hits', 0, '_source')
    if result.nil?
      # TestRun.state = "UNEXPECTED FAILURE"
      # KibanaEngine.instance.send_event_to_kibana(TestRun.state, "ERROR", "Kibana Query returned nil. Query: #{query}")
      raise "No results found for query: '#{query}'"
    end
    result
  end

  def retrieve_entries_from_kibana(query)
    response = kibana_query(query)
    result = response.dig('hits', 'hits').map {|entry| entry.dig('_source')}
    if result.nil?
      # TestRun.state = "UNEXPECTED FAILURE"
      # KibanaEngine.instance.send_event_to_kibana(TestRun.state, "ERROR", "Kibana Query returned nil. Query: #{query}")
      raise "No results found for query: '#{query}'"
    end
    result
  end

  def kibana_query(query)
    uri = URI.parse("#{kibana_url}/_search?q=#{query}&pretty&size=10000")
    request = Net::HTTP::Get.new(uri)

    req_options = {
        use_ssl: uri.scheme == "https",
    }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end
    response = JSON(response.body)
  end

  def send_event_to_kibana(type, log_level, message = nil, is_logging_error_message = false)
    if @config['REMOTE_LOGGING']
      index_line = "{\"index\":{\"_id\":\"#{SecureRandom.uuid}\"}"
      kibana_info = kibana_event_info(type, log_level, message)
      data_line = Metadata.instance.content.merge(kibana_info).to_json if kibana_info
      # data needs to be ndjson (newline delimited JSON)
      data = "#{index_line}\n#{data_line}\n"

      uri = URI.parse("#{kibana_url}/automation/_bulk?pretty")
      request = Net::HTTP::Post.new(uri)
      request.content_type = "application/x-ndjson"
      request.body = data

      req_options = {
          use_ssl: uri.scheme == "https",
      }


      Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
        response = http.request(request)
        if JSON.parse(response.body)['errors'] && !is_logging_error_message
          reason = JSON.parse(response.body).dig('items', 0, 'index', 'error').to_s
          send_event_to_kibana("KIBANA_SEND_ERROR", "ERROR", "Failed to send payload.  Reason: #{reason.to_json}", true)
          File.open('bad_kibana_data.json', 'a+') do |file|
            file.puts "#{Time.now} - #{data}"
            file.puts "Reason For ELK fail:\n#{reason.to_yaml}"
            file.puts "Elk response body:\n#{JSON.parse(response.body).to_yaml}"
          end
        end

      end
    end
  end

  private

  def kibana_event_info(type, log_level, message = nil)
    extra_data = {type: type, level: log_level, event_time: Time.now}
    extra_data.merge!({message: message}) unless message.nil?
    # extra_data.merge!({scenario_elapsed_time: scenario_elapsed_time}) if TestRun.state == 'SCENARIO_RUNNING'
    (TestRun.state == 'SCENARIO_RUNNING') ? extra_data.merge!({scenario_elapsed_time: scenario_elapsed_time}) : extra_data
  end

  def scenario_elapsed_time
    (Time.now - Metadata.instance.content[:scenario_start_time]).round(2) rescue nil
  end
end