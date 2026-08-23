require 'json'

# One unit of LLM-bound work: a single note's snippet windows plus the
# bookkeeping needed to interpret the response.
#   windows:     [[start, end], ...] char ranges of note text to send (merged)
#   sent_words:  [{word:, occs: [{start:, end:}, ...]}] unresolved candidates
#   local_spans: spans already resolved locally, to be merged into the output
NoteJob = Struct.new(:note, :windows, :sent_words, :local_spans, :audit_full,
                     keyword_init: true) do
  def note_id
    note['note_id']
  end
end

# A packed request: several notes' windows joined into one prompt, with a
# segment table mapping prompt offsets back to per-note text offsets.
class Batch
  SEPARATOR = "\n\n".freeze

  attr_reader :jobs, :segments

  def initialize
    @jobs = []
    @segments = [] # {job:, prompt_start:, note_start:, length:}
    @parts = []
    @chars = 0
  end

  def add(job)
    @jobs << job
    job.windows.each do |ws, we|
      @chars += SEPARATOR.length unless @parts.empty?
      text = job.note['text'][ws...we]
      @segments << { job: job, prompt_start: @chars, note_start: ws,
                     length: text.length }
      @parts << text
      @chars += text.length
    end
  end

  def prompt
    @parts.join(SEPARATOR)
  end

  def chars
    @chars
  end

  def would_fit?(job, max_chars)
    extra = job.windows.sum { |ws, we| we - ws } +
            SEPARATOR.length * job.windows.length
    @chars + extra <= max_chars
  end

  # Extraction offsets are into the prompt; map back to (job, note offsets).
  # Extractions crossing a segment boundary (can't really happen — separators
  # are word boundaries) are dropped.
  def map(prompt_start, prompt_end)
    seg = @segments.find do |s|
      prompt_start >= s[:prompt_start] &&
        prompt_end <= s[:prompt_start] + s[:length]
    end
    return nil unless seg
    delta = seg[:note_start] - seg[:prompt_start]
    { job: seg[:job], start: prompt_start + delta, end: prompt_end + delta }
  end
end

# Accumulates NoteJobs into Batches capped comfortably under the per-request
# token limit (tokens = ceil(chars/4), so max_tokens*4 chars).
class Packer
  def initialize(max_tokens: 7500)
    @max_chars = max_tokens * 4
    @batch = Batch.new
  end

  # -> a full Batch ready to send, or nil if the job was absorbed.
  def add(job)
    if @batch.jobs.any? && !@batch.would_fit?(job, @max_chars)
      full = @batch
      @batch = Batch.new
      @batch.add(job)
      full
    else
      @batch.add(job)
      nil
    end
  end

  def flush
    return nil if @batch.jobs.empty?
    full = @batch
    @batch = Batch.new
    full
  end
end
