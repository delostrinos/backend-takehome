require 'set'

# Local (free) triage: find capitalized words that could be first names the
# NER missed. Paranoid by design — false positives only cost tokens, false
# negatives cost compliance.
module Candidates
  WORD_RE = /\b[A-Z][a-z]{2,}\b/

  # Structural / clinical vocabulary. A real name colliding with this list
  # would be invisible to the pipeline — that risk is bounded by the
  # full-note audit stream (see DESIGN.md). Deliberately does NOT include
  # word-names like Grace, Hope, Faith, Joy, Winter, River.
  STOPWORDS = Set.new(%w[
    The And But Nor For Yet Then Than This That These Those There Here
    She They His Her Their Its Our Your Has Had Have Was Were Been
    Not None All Any Some Most Both Each Per With Without Over Under
    Patient History Present Illness Review Systems Physical Exam General
    Vitals Abdomen Extremities Respiratory Cardiac Psychiatric Skin
    Neurologic Labs Assessment Plan Medications Current Interval Notes
    Date Service Denies Reports Positive Negative Alert Normal Clear
    Soft Warm Dry Call Education Ambulating Tolerating Follow Return
    Referral Discussed Chronic Major Stage Sodium Potassium Creatinine
    Basic Mucous Cranial Strength Pulses Appropriate Normocephalic
    Atraumatic Electronically Blood Pressure Room Air Within Reference
    Range Limits Panel Vital Signs Stable Continue Monitor Morning
    Safety Precautions Symptoms Nausea Vomiting Diarrhea Fever Chills
    Night Sweats Temp Strength Copd Tylenol Ibuprofen
  ]).freeze

  # -> [{word:, start:, end:}] for every capitalized word not covered by an
  # existing annotation and not a stopword. Offsets are character offsets
  # into text, matching the note's annotation offsets.
  def self.extract(text, annotations)
    spans = annotations.map { |a| [a['start'], a['end']] }
    out = []
    pos = 0
    while (m = WORD_RE.match(text, pos))
      s = m.begin(0)
      e = m.end(0)
      pos = e
      word = m[0]
      next if STOPWORDS.include?(word)
      next if spans.any? { |cs, ce| s >= cs && e <= ce }
      out << { word: word, start: s, end: e }
    end
    out
  end
end
