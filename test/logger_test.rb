# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'logger'
require 'semantic_logger'

# Unit Test for SemanticLogger::Logger
class LoggerTest < Test::Unit::TestCase
  context SemanticLogger::Logger do
    # Test each filter
    [ nil, /\ALogger/, Proc.new{|l| (/\AExclude/ =~ l.message).nil? } ].each do |filter|
      context "filter: #{filter.class.name}" do
        setup do
          # Use a mock logger that just keeps the last logged entry in an instance
          # variable
          SemanticLogger.default_level = :trace
          @mock_logger = MockLogger.new
          appender = SemanticLogger.add_appender(@mock_logger)
          appender.filter = filter

          # Add mock metric subscriber
          $last_metric = nil
          SemanticLogger.on_metric do |log_struct|
            $last_metric = log_struct.dup
          end

          # Use this test's class name as the application name in the log output
          @logger   = SemanticLogger[self.class]
          @hash     = { :session_id => 'HSSKLEU@JDK767', :tracking_number => 12345 }
          @hash_str = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
          assert_equal [], @logger.tags
        end

        teardown do
          # Remove all appenders
          SemanticLogger.appenders.each{|appender| SemanticLogger.remove_appender(appender)}
        end

        # Ensure that any log level can be logged
        SemanticLogger::LEVELS.each do |level|
          context level do
            should "log" do
              @logger.send(level, 'hello world', @hash) { "Calculations" }
              SemanticLogger.flush
              assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] LoggerTest -- hello world -- Calculations -- #{@hash_str}/, @mock_logger.message
            end

            should "exclude log messages using Proc filter" do
              if filter.is_a?(Proc)
                @logger.send(level, 'Exclude this log message', @hash) { "Calculations" }
                SemanticLogger.flush
                assert_nil @mock_logger.message
              end
            end

            should "exclude log messages using RegExp filter" do
              if filter.is_a?(Regexp)
                logger = SemanticLogger::Logger.new('NotLogger', :trace, filter)
                logger.send(level, 'Ignore all log messages from this class', @hash) { "Calculations" }
                SemanticLogger.flush
                assert_nil @mock_logger.message
              end
            end

          end
        end

        context "tagged logging" do
          should "add tags to log entries" do
            @logger.tagged('12345', 'DJHSFK') do
              @logger.info('Hello world')
              SemanticLogger.flush
              assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \[12345\] \[DJHSFK\] LoggerTest -- Hello world/, @mock_logger.message
            end
          end

          should "add embedded tags to log entries" do
            @logger.tagged('First Level', 'tags') do
              @logger.tagged('Second Level') do
                @logger.info('Hello world')
                SemanticLogger.flush
                assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \[First Level\] \[tags\] \[Second Level\] LoggerTest -- Hello world/, @mock_logger.message
              end
              assert_equal 2, @logger.tags.count, @logger.tags
              assert_equal 'First Level', @logger.tags.first
              assert_equal 'tags', @logger.tags.last
            end
          end

          should "add payload to log entries" do
            hash = {:tracking_number=>"123456", :even=>2, :more=>"data"}
            hash_str = hash.inspect.sub("{", "\\{").sub("}", "\\}")
            @logger.with_payload(:tracking_number => '123456') do
              @logger.with_payload(:even => 2, :more => 'data') do
                @logger.info('Hello world')
                SemanticLogger.flush
                assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] LoggerTest -- Hello world -- #{hash_str}/, @mock_logger.message
              end
            end
          end

          context "Ruby Logger" do
            # Ensure that any log level can be logged
            Logger::Severity.constants.each do |level|
              should "log Ruby logger #{level} info" do
                @logger.level = Logger::Severity.const_get(level)
                if level.to_s == 'UNKNOWN'
                  assert_equal Logger::Severity.const_get('ERROR')+1, @logger.send(:level_index)
                else
                  assert_equal Logger::Severity.const_get(level)+1, @logger.send(:level_index)
                end
              end
            end
          end

          context "benchmark" do
            # Ensure that any log level can be benchmarked and logged
            SemanticLogger::LEVELS.each do |level|

              context 'direct method' do
                should "log #{level} info" do
                  assert_equal "result", @logger.send("benchmark_#{level}".to_sym, 'hello world') { "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world/, @mock_logger.message
                end

                should "log #{level} info with payload" do
                  assert_equal "result", @logger.send("benchmark_#{level}".to_sym, 'hello world', :payload => @hash) { "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message
                end

                should "not log #{level} info when block is faster than :min_duration" do
                  assert_equal "result", @logger.send("benchmark_#{level}".to_sym, 'hello world', :min_duration => 500) { "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_nil @mock_logger.message
                end

                should "log #{level} info when block duration exceeds :min_duration" do
                  assert_equal "result", @logger.send("benchmark_#{level}".to_sym, 'hello world', :min_duration => 200, :payload => @hash) { sleep 0.5; "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message
                end

                should "log #{level} info with an exception" do
                  assert_raise RuntimeError do
                    @logger.send("benchmark_#{level}", 'hello world', :payload => @hash) { raise RuntimeError.new("Test") } # Measure duration of the supplied block
                  end
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world -- Exception: RuntimeError: Test -- #{@hash_str}/, @mock_logger.message
                end

                should "log #{level} info with metric" do
                  metric_name = '/my/custom/metric'
                  assert_equal "result", @logger.send("benchmark_#{level}".to_sym, 'hello world', :metric => metric_name) { "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world/, @mock_logger.message
                  assert metric_name, $last_metric.metric
                end
              end

              context 'generic method' do
                should "log #{level} info" do
                  assert_equal "result", @logger.benchmark(level, 'hello world') { "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world/, @mock_logger.message
                end

                should "log #{level} info with payload" do
                  assert_equal "result", @logger.benchmark(level, 'hello world', :payload => @hash) { "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message
                end

                should "not log #{level} info when block is faster than :min_duration" do
                  assert_equal "result", @logger.benchmark(level, 'hello world', :min_duration => 500) { "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_nil @mock_logger.message
                end

                should "log #{level} info when block duration exceeds :min_duration" do
                  assert_equal "result", @logger.benchmark(level, 'hello world', :min_duration => 200, :payload => @hash) { sleep 0.5; "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message
                end

                should "log #{level} info with an exception" do
                  assert_raise RuntimeError do
                    @logger.benchmark(level, 'hello world', :payload => @hash) { raise RuntimeError.new("Test") } # Measure duration of the supplied block
                  end
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world -- Exception: RuntimeError: Test -- #{@hash_str}/, @mock_logger.message
                end

                should "log #{level} info with metric" do
                  metric_name = '/my/custom/metric'
                  assert_equal "result", @logger.benchmark(level, 'hello world', :metric => metric_name) { "result" } # Measure duration of the supplied block
                  SemanticLogger.flush
                  assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world/, @mock_logger.message
                  assert metric_name, $last_metric.metric
                end
              end
            end

            should "log when the block performs a return" do
              assert_equal "Good", function_with_return(@logger)
              SemanticLogger.flush
              assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \(\d+\.\dms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message
            end
          end
        end
      end
    end
  end

  # Make sure that benchmark still logs when a block uses return to return from
  # a function
  def function_with_return(logger)
    logger.benchmark_info('hello world', :payload => @hash) do
      return "Good"
    end
    "Bad"
  end

end