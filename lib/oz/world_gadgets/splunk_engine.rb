require 'uri'
require 'json'
require 'net/https'
require 'open-uri'
require_relative 'configuration_engine'
require 'singleton'
require_relative '../helpers/grid_helper.rb'

class SplunkEngine
  include Singleton
  attr_reader :token

  def initialize(splunk_token = nil)
    @config = Metadata.instance.content[:config].nil? ? ConfigurationEngine.new : Metadata.instance.content[:config]
    set_token(@config['SPLUNK_TOKEN']) || set_token(splunk_token)
    @splunk_service ||= "#{base_url}/services/collector"
  end

  def base_url
    host = @config['SPLUNK_URL']
    port = @config['SPLUNK_PORT']
    "#{host}:#{port}"
  end

  def query_url
    host = @config['SPLUNK_QUERY_URL']
    port = @config['SPLUNK_QUERY_PORT']
    "#{host}:#{port}"
  end

  def log_event(event_hash)
    begin
      retries ||= 0
      if @config['REMOTE_LOGGING']
        hash = {event: event_hash}
        json = JSON.fast_generate(hash)
        uri = URI.parse(@splunk_service)
        post_ssl_message(uri, {'Authorization' => @token}, json.force_encoding('utf-8'), 'application/json')
      end
    rescue => e
      retry if (retries += 1) < 3
      e.message << "Unable to log your event to Splunk!"
      raise e
    end
  end

  def send_event(type, level, message = nil)
    message = message.nil? ? Metadata.instance.content[:message] : message
    Metadata.instance.append({type: type, level: level, message: message})
    log_event(Metadata.instance.content)
  end

  def search(query)
    retries = 0
    begin
      sleep(rand(5..20))
      query = "output_mode=json&search=search #{query}"
      uri = URI.parse("#{query_url}/services/search/jobs/export?#{query}")
      get_ssl_message(uri, query)
    rescue => e
      sleep(rand(5..20))
      retries += 1
      puts "retry number #{retries}"
      get_ssl_message(uri, query)
      search(query) unless retries >= 50
      raise e
    end
  end

  private

  def set_token(my_token)
    @token = my_token.to_s.include?('Splunk ') ? my_token : 'Splunk ' + my_token
  end

  def get_ssl_message(uri, query)
    request = Net::HTTP::Get.new(uri)
    request.basic_auth(get_user, get_password)

    req_options = {
        use_ssl: uri.scheme == "https",
        verify_mode: OpenSSL::SSL::VERIFY_NONE,
    }

    response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(request)
    end

    case response
    when Net::HTTPOK
      body = parse_splunk_junk(response.body)
      raise "Splunk Query returned no results! Your Query may be wrong, or the data you are searching for does not exist.\nQuery: \"#{query}\"" if body.empty?
      body
    else
      object = JSON.parse(response.body, object_class: OpenStruct)
      raise "\nSplunk Query failed with response code: #{response.code}. Message: #{object.messages[0].text}."
    end
    # end
  end

  def parse_splunk_junk(splunk_json)
    begin
      #this is for standard queries to splunk (asking for a list of results)
      result = splunk_json.split("\r\n").map {|it| JSON.parse(it)['result']}.reject(&:nil?).map {|it| JSON.parse(it['_raw']).inject({}) {|h, (k, v)| h[k] = eval(v.inspect); h}}
    rescue => e
      #this is for aggregate queries to splunk (asking for grouped results)
      result = splunk_json.split("\r\n").map {|it| JSON.parse(it)['result']}.reject(&:nil?)
    end
    result
  end

  def post_ssl_message(uri, headers, body, type)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.verify_depth = 5
    request = Net::HTTP::Post.new(uri.request_uri)
    headers.each_key.each {|key|
      request[key] = headers[key]
    }
    request.body = body
    request.content_type = type
    response = http.request(request)
    return response
  end

  def get_user
    ENV.[]('SECRET_USERNAME')
  end

  def get_password
    ENV.[]('SECRET_PASSWORD')
  end
end