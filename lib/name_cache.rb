require 'set'

# Cross-note verdict cache — the lever that makes the 10M-note math work.
# Confirmations are fail-safe (worst case: over-redaction), so one LLM "yes"
# is enough. Rejections are the dangerous direction (a wrong one is a missed
# name), so a word is only reject-cached after K rejections in K distinct
# notes with zero confirmations ever, and reject-cached words keep getting
# audit-resampled at a small rate.
class NameCache
  def initialize(reject_threshold: 3, audit_rate: 0.005, rng: Random.new)
    @confirmed = Set.new
    @reject_notes = Hash.new { |h, k| h[k] = Set.new }
    @k = reject_threshold
    @audit_rate = audit_rate
    @rng = rng
    @lock = Mutex.new
  end

  def confirmed?(word)
    @lock.synchronize { @confirmed.include?(word) }
  end

  def confirm!(word)
    @lock.synchronize do
      @confirmed.add(word)
      @reject_notes.delete(word) # a confirmation anywhere evicts rejections
    end
  end

  def reject!(word, note_id)
    @lock.synchronize do
      @reject_notes[word].add(note_id) unless @confirmed.include?(word)
    end
  end

  def rejected?(word)
    @lock.synchronize do
      !@confirmed.include?(word) && @reject_notes[word].size >= @k
    end
  end

  # Should this reject-cached occurrence be re-sent anyway as an audit probe?
  def audit?
    @lock.synchronize { @rng.rand < @audit_rate }
  end

  def stats
    @lock.synchronize do
      { confirmed: @confirmed.size,
        rejected: @reject_notes.count { |_, notes| notes.size >= @k } }
    end
  end
end
