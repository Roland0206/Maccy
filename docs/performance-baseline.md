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
- `Popup.firstPaintProxy`
- `Search.exact`
- `Search.fuzzy`
- `Search.regexp`
- `Search.mixed`
- `History.add.unique`
- `History.add.duplicate`

Each row includes elapsed milliseconds, resident-memory delta, output count, duplicate rate, long-text controls, and binary-payload controls.

`Popup.firstPaintProxy` is a test-only SwiftUI layout/display proxy for the popup list using an `NSHostingView` at the default 450×800 window size. It does not open the production floating panel or change app behavior.

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

Captured 2026-05-25 on macOS 26.5, arm64, Xcode 26.4.1 (17E202), while preparing issue #2 popup proxy baseline.

```csv
items,duplicate_rate,long_text_every,long_text_bytes,binary_every,binary_bytes,operation,duration_ms,memory_delta_bytes,output_count
200,0.1,10,4096,20,1024,History.load,3.909,573440,200
200,0.1,10,4096,20,1024,Popup.firstPaintProxy,48.832,7290880,200
200,0.1,10,4096,20,1024,Search.exact,1.052,16384,2
200,0.1,10,4096,20,1024,Search.fuzzy,21.541,65536,200
200,0.1,10,4096,20,1024,Search.regexp,1.064,98304,200
200,0.1,10,4096,20,1024,Search.mixed,1.733,0,200
200,0.1,10,4096,20,1024,History.add.unique,6.333,311296,201
200,0.1,10,4096,20,1024,History.add.duplicate,4.045,0,202
1000,0.1,10,4096,20,1024,History.load,17.489,2768896,1000
1000,0.1,10,4096,20,1024,Popup.firstPaintProxy,46.889,7716864,1000
1000,0.1,10,4096,20,1024,Search.exact,5.137,16384,2
1000,0.1,10,4096,20,1024,Search.fuzzy,105.278,229376,1000
1000,0.1,10,4096,20,1024,Search.regexp,2.771,32768,1000
1000,0.1,10,4096,20,1024,Search.mixed,7.330,0,1000
1000,0.1,10,4096,20,1024,History.add.unique,15.183,131072,1001
1000,0.1,10,4096,20,1024,History.add.duplicate,14.756,16384,1002
10000,0.1,10,4096,20,1024,History.load,168.610,28016640,10000
10000,0.1,10,4096,20,1024,Popup.firstPaintProxy,100.594,30228480,10000
10000,0.1,10,4096,20,1024,Search.exact,48.004,0,2
10000,0.1,10,4096,20,1024,Search.fuzzy,1041.346,442368,3952
10000,0.1,10,4096,20,1024,Search.regexp,25.876,802816,10000
10000,0.1,10,4096,20,1024,Search.mixed,72.266,16384,10000
10000,0.1,10,4096,20,1024,History.add.unique,140.469,196608,10001
10000,0.1,10,4096,20,1024,History.add.duplicate,140.204,0,10002
100000,0.1,10,4096,20,1024,History.load,1679.531,143212544,100000
100000,0.1,10,4096,20,1024,Popup.firstPaintProxy,756.831,143851520,100000
100000,0.1,10,4096,20,1024,Search.exact,471.627,-7520256,2
100000,0.1,10,4096,20,1024,Search.fuzzy,10248.722,-211828736,7136
100000,0.1,10,4096,20,1024,Search.regexp,257.948,13549568,100000
100000,0.1,10,4096,20,1024,Search.mixed,744.381,-5423104,100000
100000,0.1,10,4096,20,1024,History.add.unique,1424.501,16400384,100001
100000,0.1,10,4096,20,1024,History.add.duplicate,1402.877,-8781824,100002
```

Memory deltas are point-in-time resident-size deltas; negative rows can occur when runtime cleanup happens during measurement.
