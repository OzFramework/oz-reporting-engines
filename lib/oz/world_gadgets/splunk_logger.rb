require_relative 'oz_logger'
# The SplunkLogger class is responsible for extending the OzLogger class with additional functionality and sending logging events to Splunk

class SplunkLogger < OzLogger

  def action(message)
    add_url_to_metadata
    # SplunkEngine.instance.send_event(TestRun.state,'ACTION', message) if @debug_level <= self.class.ACTION
    super(message)
  end

  def validation(message)
    add_url_to_metadata
    # SplunkEngine.instance.send_event(TestRun.state,'VALIDATION', message) if @debug_level <= self.class.ACTION
    super(message)
  end

  def validation_fail(message)
    add_url_to_metadata
    # SplunkEngine.instance.send_event(TestRun.state,'VALIDATION_FAIL', message) if @debug_level <= self.class.ACTION
    super(message)
  end

  def warn(message)
    add_url_to_metadata
    # SplunkEngine.instance.send_event(TestRun.state, 'WARNING', message) if @debug_level <= self.class.WARN
    super(message)
  end

  private

  def add_url_to_metadata
    Metadata.instance.append({current_url: @world.browser.url}) rescue nil
  end
end
