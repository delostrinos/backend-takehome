# Take-Home: Backstopping an NER Model with an LLM, at Scale

Expected time: **about 90 minutes.** We'd rather see a sharp design with
rough edges than a polished solution to the wrong problem. Timebox yourself —
where the clock forces a shortcut, take it in the code and note it in the
design doc, not the other way around.

## Scenario

We de-identify clinical data. Our internal NER model tags PHI (names, dates,
MRNs, ...) in free-text clinical notes before the data leaves our pipeline.
The model is reliable on most entity types, but its recall on **first names**
is only about **60%** — which is unacceptable for de-identification, where a
missed name is a compliance incident.

Retraining will take months. The short-term mitigation: use a commercial LLM
(GPT/Claude-class) to catch the first names our model misses.

Here's the situation you've inherited:

- The corpus is **10 million notes**, averaging **~600 tokens** each
  (roughly 150–1,300). Every note comes with the internal model's
  annotations attached — other entity types are trustworthy, first names
  are under-detected.
- The de-identified corpus is due to a customer, and the processing must
  complete within a **4-hour batch window**.
- The LLM vendor has given us these limits on our account:

  | Limit | Value |
  |---|---|
  | Input tokens per minute | **4,000,000** |
  | Requests per minute | **10,000** |
  | Max input tokens per request | **8,000** |

  The API also intermittently returns `429 Too Many Requests` and the
  occasional `500`.

Your job: design and prototype the pipeline that gets every missed first
name tagged, within the window, within the limits.

## Two scales — don't conflate them

- **The sample (what you run).** We give you `data/notes.jsonl`: 5,000
  synthetic notes drawn from the same distribution as the corpus. Your
  prototype runs on this, against the mock API, on your laptop.
- **The full run (what you design for).** All **10 million notes**, the
  production rate limits, the 4-hour window. Nobody runs this during the
  exercise — it exists on paper, in your `DESIGN.md`. Your math has to show
  that the approach your prototype demonstrates would survive it.

A pipeline that happens to clear 5,000 notes proves nothing by itself — at
2,000× that volume the constraints bite in ways the sample never shows. The
sample is for measuring (filter hit rates, tokens per note) and demonstrating
mechanics; the 10M-scale arithmetic is the actual deliverable.

## Deliverables

1. **A working prototype** (any language) that:
   - reads notes from the provided sample (`data/notes.jsonl`),
   - decides what — if anything — to send to the LLM (the provided mock API),
   - handles rate limits and transient failures,
   - emits, per note, the first-name spans it detected.

   Run it on as much or as little of the sample as fits the timebox — a few
   hundred notes is plenty to demonstrate the behavior. You will never
   process 10M documents here; that scale is addressed by your design note,
   not your laptop. Rough code is fine if the design is right.

2. **A design note** (`DESIGN.md`, ~1 page, bullets welcome) covering:
   - **The throughput math.** Show that your design fits 10M notes into
     4 hours under the limits above. Show your arithmetic.
   - **What you send to the LLM vs. what you don't, and why.** Tokens cost
     money and rate-limit budget; every one you send should earn its place.
   - **Failure story.** 429s, 500s, and a crash at hour 2 of the real run:
     how does the job resume without redoing completed work, and how would
     you know it's still on track to finish in the window? (Designing this
     is required; implementing resumability in the prototype is a bonus.)
   - **Risk.** If you filter or skip anything, what could that miss, and how
     would you bound/measure that risk on data with no ground truth?
   - **Production deltas.** What changes between your prototype and the real
     10M-document run?

## What we provide

```
data/notes.jsonl          # a 5,000-note sample of the 10M corpus (JSONL)
data/example_notes/       # a few of the same notes, pretty-printed
mock_api/server.py        # the mock LLM endpoint (stdlib, no dependencies)
```

The notes are synthetic and statistically uniform — anything you measure on
the sample (name density, filter hit rate, tokens per note) is a fair
estimate for the full corpus, which is exactly how you should use it. Slice
it if you want a smaller run.

Each note (see `data/example_notes/`):

```json
{
  "note_id": "note-0000001",
  "text": "PATIENT: Maria Ivanov\nMRN: 4829102\n...",
  "internal_annotations": [
    {"type": "FIRST_NAME", "text": "Maria", "start": 9, "end": 14},
    {"type": "MRN", "text": "4829102", "start": 27, "end": 34}
  ],
  "ground_truth_first_names": [
    {"text": "Maria", "start": 9, "end": 14}
  ]
}
```

`ground_truth_first_names` exists only because the data is synthetic — use it
to measure your pipeline's recall, but remember the real corpus has no such
field.

Run the mock LLM:

```bash
python3 mock_api/server.py --port 8000
```

```
POST /v1/extract
{"prompt": "<any text you choose to send>"}

200 → {"extractions": [{"name": "Maria", "start": 123, "end": 128}, ...],
       "usage": {"input_tokens": 214}}
429 → {"error": "rate_limit_exceeded"}  with a Retry-After header
500 → {"error": "internal_error"}
400 → {"error": "request_too_large"}  if a request exceeds the per-request cap
```

`start`/`end` are character offsets **into the prompt you sent**, so you can
map extractions back to however you packed the request. Token accounting is
`ceil(len(prompt)/4)`.

The mock's default limits are **1/100 of production** (40,000 TPM, 100 RPM)
so that laptop-scale runs hit real 429s; the 8,000-token per-request cap is
unchanged. Flags let you experiment with other regimes — but your `DESIGN.md`
math must target the **production** limits.

## Ground rules

- **Treat the mock as a real LLM.** Under the hood it's a crude simulation —
  assume the real endpoint is near-perfect at name detection but expensive
  and rate-limited, while anything you compute locally is effectively free
  but less reliable. Don't reverse-engineer the mock's internals (yes, its
  name dictionary is visible in `server.py` — pretend it isn't); a solution
  that games the simulation tells us nothing.
- Don't call a real LLM API — the mock is the point. (Feel free to note in
  `DESIGN.md` where a real model would change your design.)
- Any language, any libraries. Keep infrastructure local — no Kubernetes
  required; a sketch of the production topology in `DESIGN.md` is enough.
- Don't modify `server.py` (its flags are fair game).
- It's fine to simplify. Tell us what you simplified and why.

## What we look for

- **Economy of inference.** Did you minimize what you send to the LLM —
  in documents, in tokens per document, and in requests?
- **The math.** Does your arithmetic show the design actually fits the
  window and the limits, with sensible headroom?
- **Robustness.** Does the pipeline behave well under 429s and 500s at a
  scale where those actually happen, and is the resume story credible?
- **Judgment.** Are the tradeoffs (especially recall risk) stated,
  quantified where possible, and defensible to a compliance reviewer?

Code polish matters less than the above. A `DESIGN.md` with clear reasoning
and honest caveats beats an extra feature every time.

## Submitting

Send us a zip or repo link containing your code, `DESIGN.md`, and a short
"how to run" section (a `Makefile` or one-liner is ideal). We'll read the
design note first, then run your pipeline against the mock.
