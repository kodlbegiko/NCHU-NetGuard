# Controlled traffic acceptance — numeric evaluator

`python3 scripts/traffic_acceptance.py evidence.json` compares two independently acquired, redacted counter deltas from the same interface, interval and measurement boundary. No probes, network transfers or configuration changes are initiated.

Example synthetic fixture (not real-device evidence):

```json
{"schema_version":1,"reference":{"boundary":"physicalWire","observation_id":"fixture-1","interface_id":"fixture-nic","source_id":"reference","complete":true,"received":10000,"sent":0},"observed":{"boundary":"physicalWire","observation_id":"fixture-1","interface_id":"fixture-nic","source_id":"monitor","complete":true,"received":10100,"sent":0}}
```

Use opaque identifiers, never actual IP, SSID, MAC, path or user name. Acquire measurements using authorized local equipment or an independent capture with the same wire/payload boundary; record OS, hardware, interval start/end, capture overhead, counter continuity, other traffic isolation and reference method outside the redacted evaluator input. Test both directions, zero traffic, separate NICs, dual stack, and deliberate counter discontinuity. A reference source ID does not prove independence. TCP payload cannot be compared with physical interface bytes. Missing or interrupted observations are inconclusive. Exit 0 means only the numeric threshold was met, 1 means the numeric threshold failed, 2 means evidence cannot be compared. The 1% gate remains open until actual device evidence is independently reviewed.
