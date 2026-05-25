# Performance baseline harness

Issue #2 adds a test-only harness for current history load, search, and add paths. It does not change production behavior.

## What is measured

`MaccyTests/PerformanceBaselineTests.swift` generates synthetic history at these supported sizes:

- 200 items
- 1,000 items
- 10,000 items
- 100,000 items

For each configured size, the harness records CSV rows for:

- `History.load`
- `Search.exact`
- `Search.fuzzy`
- `Search.regexp`
- `Search.mixed`
- `History.add.unique`
- `History.add.duplicate`

Each row includes elapsed milliseconds, resident-memory delta, output count, duplicate rate, long-text controls, and binary-payload controls.

## Synthetic data controls

Full harness defaults:

```json
{
  "enabled": true,
  "sizes": [200, 1000, 10000, 100000],
  "duplicateRate": 0.1,
  "longTextEvery": 10,
  "longTextBytes": 4096,
  "binaryPayloadEvery": 20,
  "binaryPayloadBytes": 1024
}
```

- `duplicateRate`: fraction of generated items that reuse earlier content.
- `longTextEvery`: every Nth item gets long text.
- `longTextBytes`: approximate long-text payload size.
- `binaryPayloadEvery`: every Nth item gets PNG-typed binary payload data.
- `binaryPayloadBytes`: binary payload size.

## Commands

Smoke baseline, always bounded at 200 items:

```bash
xcodebuild test \
  -project Maccy.xcodeproj \
  -scheme Maccy \
  -destination 'platform=macOS' \
  -only-testing:MaccyTests/PerformanceBaselineTests/testPerformanceBaselineSmoke \
  CODE_SIGNING_ALLOWED=NO
```

Full/custom baseline uses `/tmp/maccy-performance-baseline.json`:

```bash
printf '%s' '{"enabled":true,"sizes":[200,1000,10000,100000],"duplicateRate":0.1,"longTextEvery":10,"longTextBytes":4096,"binaryPayloadEvery":20,"binaryPayloadBytes":1024}' > /tmp/maccy-performance-baseline.json
xcodebuild test \
  -project Maccy.xcodeproj \
  -scheme Maccy \
  -destination 'platform=macOS' \
  -only-testing:MaccyTests/PerformanceBaselineTests/testPerformanceBaselineFull \
  CODE_SIGNING_ALLOWED=NO
rm -f /tmp/maccy-performance-baseline.json
```

## Baseline run

Captured 2026-05-25 on macOS 26.5, arm64, Xcode 26.4.1 (17E202), commit `23a08e9`.

```csv
items,duplicate_rate,long_text_every,long_text_bytes,binary_every,binary_bytes,operation,duration_ms,memory_delta_bytes,output_count
200,0.1,10,4096,20,1024,History.load,3.849,589824,200
200,0.1,10,4096,20,1024,Search.exact,0.993,16384,2
200,0.1,10,4096,20,1024,Search.fuzzy,20.545,65536,200
200,0.1,10,4096,20,1024,Search.regexp,1.003,163840,200
200,0.1,10,4096,20,1024,Search.mixed,1.611,0,200
200,0.1,10,4096,20,1024,History.add.unique,6.070,262144,201
200,0.1,10,4096,20,1024,History.add.duplicate,3.648,16384,202
1000,0.1,10,4096,20,1024,History.load,16.907,2867200,1000
1000,0.1,10,4096,20,1024,Search.exact,4.947,0,2
1000,0.1,10,4096,20,1024,Search.fuzzy,104.087,81920,1000
1000,0.1,10,4096,20,1024,Search.regexp,2.827,49152,1000
1000,0.1,10,4096,20,1024,Search.mixed,7.532,0,1000
1000,0.1,10,4096,20,1024,History.add.unique,15.421,49152,1001
1000,0.1,10,4096,20,1024,History.add.duplicate,15.032,16384,1002
10000,0.1,10,4096,20,1024,History.load,168.420,28557312,10000
10000,0.1,10,4096,20,1024,Search.exact,46.846,16384,2
10000,0.1,10,4096,20,1024,Search.fuzzy,1045.777,425984,3952
10000,0.1,10,4096,20,1024,Search.regexp,26.913,868352,10000
10000,0.1,10,4096,20,1024,Search.mixed,72.572,0,10000
10000,0.1,10,4096,20,1024,History.add.unique,140.835,245760,10001
10000,0.1,10,4096,20,1024,History.add.duplicate,138.690,0,10002
100000,0.1,10,4096,20,1024,History.load,1918.773,243859456,100000
100000,0.1,10,4096,20,1024,Search.exact,490.687,-31064064,2
100000,0.1,10,4096,20,1024,Search.fuzzy,10856.702,-227147776,7136
100000,0.1,10,4096,20,1024,Search.regexp,285.820,29753344,100000
100000,0.1,10,4096,20,1024,Search.mixed,750.967,-262144,100000
100000,0.1,10,4096,20,1024,History.add.unique,1553.924,217317376,100001
100000,0.1,10,4096,20,1024,History.add.duplicate,1411.453,-2080768,100002
```

Memory deltas are point-in-time resident-size deltas; negative rows can occur when runtime cleanup happens during measurement.
