require 'json'
require 'set'
require 'fileutils'

# Append-only JSONL output; doubles as the resume checkpoint. One line per
# completed note, flushed per write, so a crash loses at most in-flight notes.
class ResultsWriter
  def initialize(path)
    FileUtils.mkdir_p(File.dirname(path))
    @io = File.open(path, 'a')
    @lock = Mutex.new
  end

  def write(note_id, spans)
    line = JSON.generate('note_id' => note_id, 'missed_first_names' => spans)
    @lock.synchronize do
      @io.puts(line)
      @io.flush
    end
  end

  def close
    @lock.synchronize { @io.close }
  end

  # -> [done_note_ids, confirmed_name_words] from a prior partial run.
  # Confirmed words rewarm the name cache; reject counters just re-learn.
  def self.load_done(path)
    done = Set.new
    confirmed = Set.new
    return [done, confirmed] unless File.exist?(path)
    File.foreach(path) do |line|
      row = begin
        JSON.parse(line)
      rescue JSON::ParserError
        next # torn final line from a crash mid-write
      end
      done.add(row['note_id'])
      (row['missed_first_names'] || []).each { |s| confirmed.add(s['text']) }
    end
    [done, confirmed]
  end
end
