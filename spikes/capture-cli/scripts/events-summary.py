#!/usr/bin/env python3
"""Краткая сводка events.log записи: время от первого события, ключевые поля. Только stdlib."""
import json
import sys

KEYS = ("reason", "error", "layout", "routes", "channels", "gapsMs", "atMs", "requestToFirstBufferMs",
        "teardownMs", "buildMs", "attemptsMs", "tapsRecreated", "peakDBFS", "observedChannels",
        "channelMismatches", "sampleTimeJumps", "tS", "fileSeconds", "status", "waitedMs", "offsetMs",
        "maxAbsDiffVsCh0", "alive", "tappedGone", "sessionSamplesMinusHostMs", "aggregateActualRate")
SKIP = {"process_list_changed", "devices_changed"} if "--all" not in sys.argv else set()

t0 = None
for line in open(sys.argv[1], encoding="utf-8"):
    event = json.loads(line)
    t0 = event["hostS"] if t0 is None else t0
    if event["event"] in SKIP:
        continue
    fields = {k: event[k] for k in KEYS if k in event}
    print(f'{event["hostS"] - t0:8.3f}  {event["event"]:<32} {json.dumps(fields, ensure_ascii=False)}')
