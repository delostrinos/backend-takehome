require 'net/http'
require 'json'
require 'uri'

# Continuously-refilling token bucket. take(n) BLOCKS until capacity exists —
# proactive pacing, so 429s are the exception path, not the control loop.
class TokenBucket
  def initialize(per_minute)
    @capacity = per_minute.to_f
    @level = @capacity
    @rate = per_minute / 60.0
    @last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @lock = Mutex.new
  end

  def take(n)
    loop do
      wait = @lock.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @level = [@capacity, @level + (now - @last) * @rate].min
        @last = now
        if @level >= n
          @level -= n
          0
        else
          (n - @level) / @rate
        end
      end
      return if wait.zero?
      sleep(wait + 0.02)
    end
  end
end

# Rate-limited HTTP client for the mock LLM.
#   - paces itself at `headroom` (95%) of the configured TPM/RPM limits
#   - 429: sleeps the server's Retry-After (+jitter) and retries
#   - 500: exponential backoff 0.5/1/2s (+jitter), max 3 retries; tokens are
#     re-debited on retry because the server consumes tokens on 500s
#   - 400 request_too_large: raised for the caller (shouldn't happen — the
#     packer caps prompts well under the limit)
class Client
  class RequestTooLarge < StandardError; end
  class GaveUp < StandardError; end

  MAX_500_RETRIES = 3

  def initialize(base_url:, tpm:, rpm:, stats:, headroom: 0.95)
    @uri = URI.join(base_url, '/v1/extract')
    @tokens = TokenBucket.new(tpm * headroom)
    @requests = TokenBucket.new(rpm * headroom)
    @stats = stats
  end

  # -> array of {"name","start","end"}; offsets are into the prompt sent.
  def extract(prompt)
    est_tokens = (prompt.length / 4.0).ceil
    errors_500 = 0
    loop do
      @requests.take(1)
      @tokens.take(est_tokens)
      resp = post(prompt)
      @stats.count(:requests)
      case resp.code.to_i
      when 200
        body = JSON.parse(resp.body)
        @stats.add(:tokens_spent, body.dig('usage', 'input_tokens') || est_tokens)
        return body['extractions']
      when 429
        @stats.count(:http_429)
        sleep((resp['Retry-After'] || '1').to_f + rand * 0.25)
      when 500
        @stats.count(:http_500)
        @stats.add(:tokens_spent, est_tokens) # server consumed them anyway
        errors_500 += 1
        raise GaveUp, "#{errors_500} consecutive 500s" if errors_500 > MAX_500_RETRIES
        sleep(0.5 * (2**(errors_500 - 1)) + rand * 0.25)
      when 400
        err = JSON.parse(resp.body)['error'] rescue 'bad_request'
        raise RequestTooLarge, resp.body if err == 'request_too_large'
        raise GaveUp, "400: #{resp.body}"
      else
        raise GaveUp, "unexpected HTTP #{resp.code}: #{resp.body}"
      end
    end
  end

  private

  # One persistent connection per worker thread; reconnect on socket errors.
  def post(prompt)
    tries = 0
    begin
      http = (Thread.current[:mock_llm_http] ||=
        Net::HTTP.start(@uri.host, @uri.port, read_timeout: 30))
      req = Net::HTTP::Post.new(@uri.path, 'Content-Type' => 'application/json')
      req.body = JSON.generate(prompt: prompt)
      http.request(req)
    rescue SystemCallError, IOError, EOFError, Net::OpenTimeout, Net::ReadTimeout => e
      begin
        Thread.current[:mock_llm_http]&.finish
      rescue StandardError
        nil
      end
      Thread.current[:mock_llm_http] = nil
      tries += 1
      raise GaveUp, "connection failed: #{e.class}: #{e.message}" if tries > 2
      sleep 0.2
      retry
    end
  end
end

# Thread-safe run counters shared across the pipeline.
class Stats
  def initialize
    @counters = Hash.new(0)
    @lock = Mutex.new
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def count(key)
    add(key, 1)
  end

  def add(key, n)
    @lock.synchronize { @counters[key] += n }
  end

  def [](key)
    @lock.synchronize { @counters[key] }
  end

  def elapsed
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started
  end

  def snapshot
    @lock.synchronize { @counters.dup }
  end
end
