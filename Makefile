# Two terminals: `make server` in one, then `make run && make score` in the other.

server:            ## start the mock LLM (1/100-scale limits, seeded, 2% 500s)
	python3 mock_api/server.py --port 8000 --seed 42 --error-rate 0.02

run:               ## demo slice: 500 notes
	ruby bin/pipeline --limit 500

run-all:           ## the full 5,000-note sample
	ruby bin/pipeline

score:             ## grade out/results.jsonl against ground truth
	ruby bin/score

clean:             ## remove pipeline output (and the resume checkpoint)
	rm -rf out/

.PHONY: server run run-all score clean
