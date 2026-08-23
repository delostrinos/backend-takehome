require 'json'
require 'set'

# Grades pipeline output against ground_truth_first_names. This is the ONLY
# place ground truth is read — the pipeline itself never sees it (the real
# corpus has no such field).
module Scorer
  def self.run(notes_path:, results_path:)
    results = {}
    File.foreach(results_path) do |line|
      row = JSON.parse(line)
      results[row['note_id']] = row['missed_first_names'] || []
    end

    notes_total = 0
    covered = 0
    ner_found = 0
    gt_total = 0
    missed_total = 0
    caught = 0
    false_positives = 0
    fp_examples = []
    miss_examples = []

    File.foreach(notes_path) do |line|
      note = JSON.parse(line)
      notes_total += 1
      found = results[note['note_id']]
      next unless found # note wasn't in this run's slice

      covered += 1
      gt = note['ground_truth_first_names']
                .map { |g| [g['start'], g['end']] }.to_set
      ner = note['internal_annotations']
                .select { |a| a['type'] == 'FIRST_NAME' }
                .map { |a| [a['start'], a['end']] }.to_set
      pipeline = found.map { |s| [s['start'], s['end']] }.to_set

      gt_total += gt.size
      ner_found += (gt & ner).size
      missed = gt - ner
      missed_total += missed.size
      caught += (missed & pipeline).size

      (pipeline - gt).each do |s, e|
        false_positives += 1
        fp_examples << "#{note['note_id']}: #{note['text'][s...e].inspect}" if fp_examples.size < 5
      end
      (missed - pipeline).each do |s, e|
        miss_examples << "#{note['note_id']}: #{note['text'][s...e].inspect}" if miss_examples.size < 5
      end
    end

    pct = ->(a, b) { b.zero? ? 'n/a' : format('%.2f%%', 100.0 * a / b) }
    puts "notes scored:            #{covered} of #{notes_total} in corpus"
    puts "ground-truth names:      #{gt_total}"
    puts "found by NER:            #{ner_found} (#{pct.call(ner_found, gt_total)} recall — the ~60% problem)"
    puts "missed by NER:           #{missed_total}"
    puts "caught by pipeline:      #{caught} (backstop recall: #{pct.call(caught, missed_total)})"
    puts "combined NER+pipeline:   #{ner_found + caught} (#{pct.call(ner_found + caught, gt_total)} recall)"
    puts "false-positive spans:    #{false_positives} (over-redaction; fail-safe direction)"
    unless fp_examples.empty?
      puts '  e.g. ' + fp_examples.join('; ')
    end
    unless miss_examples.empty?
      puts "still-missed examples:   #{miss_examples.join('; ')}"
    end
    miss_examples.empty?
  end
end
