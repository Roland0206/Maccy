# Performance baseline harness

Issue #2 adds a test-only harness for current history load, search, and add paths. It does not change production behavior.

## What is measured

`MaccyTests/PerformanceBaselineTests.swift` generates synthetic history at these supported sizes:

- 200 items
- 1,000 items
- 10,000 items
- 100,000 items

For each configured size, the harness records CSV rows for:

- `History.load.legacy`
- `History.load.archivePopup`
- `Popup.firstPaintProxy.legacy`
- `Popup.firstPaintProxy.archivePopup`
- `Search.exact`
- `Search.fuzzy`
- `Search.regexp`
- `Search.mixed`
- `History.add.unique`
- `History.add.duplicate`

Each row includes elapsed milliseconds, resident-memory delta, output count, duplicate rate, long-text controls, and binary-payload controls.

`Popup.firstPaintProxy.*` is a test-only SwiftUI layout/display proxy for the popup list using an `NSHostingView` at the default 450×800 window size. It does not open the production floating panel or change app behavior.

`*.archivePopup` rows import synthetic history into a temporary archive DB, then measure popup open through pinned + first recent page DTOs. They should return at most `popupRecentPageSize` rows (default 200), so 10k/100k runs show bounded popup load versus full legacy history load.

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
200,0.1,10,4096,20,1024,History.load,3.675,589824,200
200,0.1,10,4096,20,1024,Popup.firstPaintProxy,41.873,7454720,200
200,0.1,10,4096,20,1024,Search.exact,0.990,16384,2
200,0.1,10,4096,20,1024,Search.fuzzy,20.431,49152,200
200,0.1,10,4096,20,1024,Search.regexp,0.941,98304,200
200,0.1,10,4096,20,1024,Search.mixed,1.615,0,200
200,0.1,10,4096,20,1024,History.add.unique,5.766,294912,201
200,0.1,10,4096,20,1024,History.add.duplicate,2.987,32768,201
1000,0.1,10,4096,20,1024,History.load,16.390,2719744,1000
1000,0.1,10,4096,20,1024,Popup.firstPaintProxy,43.528,7847936,1000
1000,0.1,10,4096,20,1024,Search.exact,4.991,16384,2
1000,0.1,10,4096,20,1024,Search.fuzzy,102.911,163840,1000
1000,0.1,10,4096,20,1024,Search.regexp,2.805,49152,1000
1000,0.1,10,4096,20,1024,Search.mixed,7.389,0,1000
1000,0.1,10,4096,20,1024,History.add.unique,15.721,131072,1001
1000,0.1,10,4096,20,1024,History.add.duplicate,7.729,49152,1001
10000,0.1,10,4096,20,1024,History.load,166.854,27934720,10000
10000,0.1,10,4096,20,1024,Popup.firstPaintProxy,101.310,30654464,10000
10000,0.1,10,4096,20,1024,Search.exact,47.277,0,2
10000,0.1,10,4096,20,1024,Search.fuzzy,1030.025,475136,3952
10000,0.1,10,4096,20,1024,Search.regexp,27.962,835584,10000
10000,0.1,10,4096,20,1024,Search.mixed,73.756,0,10000
10000,0.1,10,4096,20,1024,History.add.unique,141.810,147456,10001
10000,0.1,10,4096,20,1024,History.add.duplicate,68.391,32768,10001
100000,0.1,10,4096,20,1024,History.load,1658.632,123387904,100000
100000,0.1,10,4096,20,1024,Popup.firstPaintProxy,791.231,176029696,100000
100000,0.1,10,4096,20,1024,Search.exact,468.589,-17006592,2
100000,0.1,10,4096,20,1024,Search.fuzzy,10326.960,-222035968,7136
100000,0.1,10,4096,20,1024,Search.regexp,275.420,-11878400,100000
100000,0.1,10,4096,20,1024,Search.mixed,777.603,-186974208,100000
100000,0.1,10,4096,20,1024,History.add.unique,1616.221,4227072,100001
100000,0.1,10,4096,20,1024,History.add.duplicate,743.385,-393216,100001
```

Memory deltas are point-in-time resident-size deltas; negative rows can occur when runtime cleanup happens during measurement.

Note: historical CSV above predates issue #8 operation renames. New runs emit `.legacy` and `.archivePopup` rows for direct comparison.

## Issue #8 archive popup comparison run

Captured 2026-05-26 on same local macOS/Xcode test host while implementing issue #8.

```csv
items,duplicate_rate,long_text_every,long_text_bytes,binary_every,binary_bytes,operation,duration_ms,memory_delta_bytes,output_count
10000,0.1,10,4096,20,1024,History.load.legacy,272.058,47562752,10000
10000,0.1,10,4096,20,1024,History.load.archivePopup,32.778,4882432,200
10000,0.1,10,4096,20,1024,Popup.firstPaintProxy.legacy,139.155,32292864,10000
10000,0.1,10,4096,20,1024,Popup.firstPaintProxy.archivePopup,50.353,5914624,200
100000,0.1,10,4096,20,1024,History.load.legacy,2653.716,300580864,100000
100000,0.1,10,4096,20,1024,History.load.archivePopup,57.010,4472832,200
100000,0.1,10,4096,20,1024,Popup.firstPaintProxy.legacy,846.470,447234048,100000
100000,0.1,10,4096,20,1024,Popup.firstPaintProxy.archivePopup,36.260,5652480,200
```
