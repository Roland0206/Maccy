// swiftlint:disable file_length
import AppKit
import Defaults
import MachO
import SwiftUI
import XCTest
@testable import Maccy

@MainActor
final class PerformanceBaselineTests: XCTestCase { // swiftlint:disable:this type_body_length
  private var savedSearchMode = Defaults[.searchMode]
  private var savedSearchVisibility = Defaults[.searchVisibility]
  private var savedShowApplicationIcons = Defaults[.showApplicationIcons]
  private var savedShowFooter = Defaults[.showFooter]
  private var savedShowSearch = Defaults[.showSearch]
  private var savedShowTitle = Defaults[.showTitle]
  private var savedSize = Defaults[.size]
  private var savedSortBy = Defaults[.sortBy]
  private var savedWindowSize = Defaults[.windowSize]

  override func setUp() {
    super.setUp()
    savedSearchMode = Defaults[.searchMode]
    savedSearchVisibility = Defaults[.searchVisibility]
    savedShowApplicationIcons = Defaults[.showApplicationIcons]
    savedShowFooter = Defaults[.showFooter]
    savedShowSearch = Defaults[.showSearch]
    savedShowTitle = Defaults[.showTitle]
    savedSize = Defaults[.size]
    savedSortBy = Defaults[.sortBy]
    savedWindowSize = Defaults[.windowSize]

    Defaults[.searchVisibility] = .always
    Defaults[.showApplicationIcons] = false
    Defaults[.showFooter] = true
    Defaults[.showSearch] = true
    Defaults[.showTitle] = true
    Defaults[.sortBy] = .lastCopiedAt
    Defaults[.windowSize] = NSSize(width: 450, height: 800)
  }

  override func tearDown() {
    Defaults[.searchMode] = savedSearchMode
    Defaults[.searchVisibility] = savedSearchVisibility
    Defaults[.showApplicationIcons] = savedShowApplicationIcons
    Defaults[.showFooter] = savedShowFooter
    Defaults[.showSearch] = savedShowSearch
    Defaults[.showTitle] = savedShowTitle
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.windowSize] = savedWindowSize
    super.tearDown()
  }

  func testPerformanceBaselineSmoke() async throws {
    let config = SyntheticHistoryConfig(itemCount: 200)
    let measurements = try await runBaseline(configs: [config])

    XCTAssertFalse(measurements.isEmpty)
    print(BaselineReport.render(measurements))
  }

  func testPerformanceBaselineFull() async throws {
    let runConfig = try loadRunConfig()
    guard environment["MACCY_PERFORMANCE_BASELINE"] == "1" || runConfig?.enabled == true else {
      throw XCTSkip("Set MACCY_PERFORMANCE_BASELINE=1 or write /tmp/maccy-performance-baseline.json")
    }

    let configs = configuredSizes(runConfig: runConfig).map { size in
      SyntheticHistoryConfig(
        itemCount: size,
        duplicateRate: configuredDouble(
          "MACCY_PERFORMANCE_DUPLICATE_RATE",
          default: runConfig?.duplicateRate ?? 0.1
        ),
        longTextEvery: configuredInt(
          "MACCY_PERFORMANCE_LONG_TEXT_EVERY",
          default: runConfig?.longTextEvery ?? 10
        ),
        longTextBytes: configuredInt(
          "MACCY_PERFORMANCE_LONG_TEXT_BYTES",
          default: runConfig?.longTextBytes ?? 4_096
        ),
        binaryPayloadEvery: configuredInt(
          "MACCY_PERFORMANCE_BINARY_EVERY",
          default: runConfig?.binaryPayloadEvery ?? 20
        ),
        binaryPayloadBytes: configuredInt(
          "MACCY_PERFORMANCE_BINARY_BYTES",
          default: runConfig?.binaryPayloadBytes ?? 1_024
        )
      )
    }

    let measurements = try await runBaseline(configs: configs)

    XCTAssertFalse(measurements.isEmpty)
    print(BaselineReport.render(measurements))
  }

  private func runBaseline(configs: [SyntheticHistoryConfig]) async throws -> [BaselineMeasurement] {
    var measurements: [BaselineMeasurement] = []

    for config in configs {
      Defaults[.size] = config.itemCount + 10
      let generator = SyntheticHistoryGenerator(config: config)
      let seededItems = generator.makeItems()
      let store = InMemoryHistoryStore(items: seededItems)
      let history = History(historyStore: store)

      measurements.append(try await measure(config: config, operation: "History.load") {
        try await history.load()
        return history.all.count
      })

      measurements.append(measure(config: config, operation: "Popup.firstPaintProxy") {
        measurePopupFirstPaintProxy(history: history)
      })

      for mode in Search.Mode.allCases {
        Defaults[.searchMode] = mode
        measurements.append(measure(config: config, operation: "Search.\(mode.rawValue)") {
          Search().search(string: query(for: mode), within: history.all).count
        })
      }

      measurements.append(measure(config: config, operation: "History.add.unique") {
        let item = generator.makeItem(index: config.itemCount + 1, contentIndex: config.itemCount + 1)
        _ = history.add(item)
        return history.all.count
      })

      measurements.append(measure(config: config, operation: "History.add.duplicate") {
        let item = generator.makeItem(index: 0, contentIndex: 0)
        _ = history.add(item)
        return history.all.count
      })
    }

    return measurements
  }

  private func measurePopupFirstPaintProxy(history: History) -> Int {
    let savedAppState = AppStateSnapshot.capture()
    defer { savedAppState.restore() }

    configurePopupProxyState(history: history)

    let size = Defaults[.windowSize]
    let host = NSHostingView(rootView: PopupFirstPaintProxyView())
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()

    return history.items.count
  }

  private func configurePopupProxyState(history: History) {
    let appState = AppState.shared
    let footer = Footer()

    appState.history = history
    appState.footer = footer
    appState.navigator = NavigationManager(history: history, footer: footer)
    appState.preview = SlideoutController(
      onContentResize: { Defaults[.windowSize].width = $0 },
      onSlideoutResize: { Defaults[.previewWidth] = $0 }
    )
    appState.preview.contentWidth = Defaults[.windowSize].width
    appState.preview.slideoutWidth = Defaults[.previewWidth]
  }

  private func query(for mode: Search.Mode) -> String {
    switch mode {
    case .exact:
      "needle-000001"
    case .fuzzy:
      "ndl000001"
    case .regexp:
      "needle-[0-9]{6}"
    case .mixed:
      "needle-[0-9]{6}"
    }
  }

  private func measure(
    config: SyntheticHistoryConfig,
    operation: String,
    _ block: () throws -> Int
  ) rethrows -> BaselineMeasurement {
    let memoryBefore = residentMemoryBytes()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let outputCount = try block()
    let endedAt = DispatchTime.now().uptimeNanoseconds
    let memoryAfter = residentMemoryBytes()

    return BaselineMeasurement(
      config: config,
      operation: operation,
      durationNanoseconds: endedAt - startedAt,
      memoryDeltaBytes: Int64(memoryAfter) - Int64(memoryBefore),
      outputCount: outputCount
    )
  }

  private func measure(
    config: SyntheticHistoryConfig,
    operation: String,
    _ block: () async throws -> Int
  ) async rethrows -> BaselineMeasurement {
    let memoryBefore = residentMemoryBytes()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let outputCount = try await block()
    let endedAt = DispatchTime.now().uptimeNanoseconds
    let memoryAfter = residentMemoryBytes()

    return BaselineMeasurement(
      config: config,
      operation: operation,
      durationNanoseconds: endedAt - startedAt,
      memoryDeltaBytes: Int64(memoryAfter) - Int64(memoryBefore),
      outputCount: outputCount
    )
  }

  private func configuredSizes(runConfig: BaselineRunConfig?) -> [Int] {
    guard let rawSizes = environment["MACCY_PERFORMANCE_SIZES"] else {
      return runConfig?.sizes ?? [200, 1_000, 10_000, 100_000]
    }

    let sizes = rawSizes
      .split(separator: ",")
      .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

    return sizes.isEmpty ? (runConfig?.sizes ?? [200, 1_000, 10_000, 100_000]) : sizes
  }

  private func loadRunConfig() throws -> BaselineRunConfig? {
    let configPath = environment["MACCY_PERFORMANCE_CONFIG"] ?? "/tmp/maccy-performance-baseline.json"
    let configURL = URL(fileURLWithPath: configPath)
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      return nil
    }

    let data = try Data(contentsOf: configURL)
    return try JSONDecoder().decode(BaselineRunConfig.self, from: data)
  }

  private func configuredInt(_ key: String, default defaultValue: Int) -> Int {
    guard let rawValue = environment[key], let value = Int(rawValue) else {
      return defaultValue
    }

    return value
  }

  private func configuredDouble(_ key: String, default defaultValue: Double) -> Double {
    guard let rawValue = environment[key], let value = Double(rawValue) else {
      return defaultValue
    }

    return value
  }

  private var environment: [String: String] {
    ProcessInfo.processInfo.environment
  }
}

@MainActor
private struct AppStateSnapshot {
  let history: History
  let footer: Footer
  let navigator: NavigationManager
  let preview: SlideoutController

  static func capture() -> AppStateSnapshot {
    let appState = AppState.shared
    return AppStateSnapshot(
      history: appState.history,
      footer: appState.footer,
      navigator: appState.navigator,
      preview: appState.preview
    )
  }

  func restore() {
    let appState = AppState.shared
    appState.history = history
    appState.footer = footer
    appState.navigator = navigator
    appState.preview = preview
  }
}

private struct PopupFirstPaintProxyView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @FocusState private var searchFocused: Bool

  var body: some View {
    ZStack {
      VisualEffectView()

      VStack(spacing: 0) {
        ListHeaderView(searchFocused: $searchFocused, searchQuery: $appState.history.searchQuery)
          .padding(.top, Popup.verticalPadding)
          .padding(.horizontal, Popup.horizontalPadding + 10)

        HistoryListView(
          searchQuery: $appState.history.searchQuery,
          searchFocused: $searchFocused
        )

        FooterView(footer: appState.footer)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: Defaults[.windowSize].width, height: Defaults[.windowSize].height)
    .environment(appState)
    .environment(modifierFlags)
    .environment(\.scenePhase, .active)
  }
}

private struct BaselineRunConfig: Decodable {
  let enabled: Bool
  let sizes: [Int]?
  let duplicateRate: Double?
  let longTextEvery: Int?
  let longTextBytes: Int?
  let binaryPayloadEvery: Int?
  let binaryPayloadBytes: Int?
}

private struct SyntheticHistoryConfig {
  let itemCount: Int
  let duplicateRate: Double
  let longTextEvery: Int
  let longTextBytes: Int
  let binaryPayloadEvery: Int
  let binaryPayloadBytes: Int

  init(
    itemCount: Int,
    duplicateRate: Double = 0.1,
    longTextEvery: Int = 10,
    longTextBytes: Int = 4_096,
    binaryPayloadEvery: Int = 20,
    binaryPayloadBytes: Int = 1_024
  ) {
    self.itemCount = itemCount
    self.duplicateRate = duplicateRate
    self.longTextEvery = longTextEvery
    self.longTextBytes = longTextBytes
    self.binaryPayloadEvery = binaryPayloadEvery
    self.binaryPayloadBytes = binaryPayloadBytes
  }
}

private struct SyntheticHistoryGenerator {
  let config: SyntheticHistoryConfig

  func makeItems() -> [HistoryItem] {
    (0..<config.itemCount).map { index in
      makeItem(index: index, contentIndex: contentIndex(for: index))
    }
  }

  func makeItem(index: Int, contentIndex: Int) -> HistoryItem {
    let item = HistoryItem(contents: contents(index: index, contentIndex: contentIndex))
    item.title = title(index: index, contentIndex: contentIndex)
    item.application = "org.p0deje.Maccy.PerformanceBaseline"
    item.firstCopiedAt = Date(timeIntervalSince1970: TimeInterval(index))
    item.lastCopiedAt = Date(timeIntervalSince1970: TimeInterval(index))
    item.numberOfCopies = 1

    return item
  }

  private func contentIndex(for index: Int) -> Int {
    let duplicateRate = min(max(config.duplicateRate, 0), 0.95)
    let uniqueCount = max(1, Int((Double(config.itemCount) * (1 - duplicateRate)).rounded(.up)))
    return index % uniqueCount
  }

  private func contents(index: Int, contentIndex: Int) -> [HistoryItemContent] {
    var contents = [HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: textPayload(index: index, contentIndex: contentIndex).data(using: .utf8)
    )]

    if includesBinaryPayload(index: index) {
      contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.png.rawValue,
        value: binaryPayload(seed: contentIndex)
      ))
    }

    return contents
  }

  private func textPayload(index: Int, contentIndex: Int) -> String {
    let base = title(index: index, contentIndex: contentIndex)
    guard includesLongText(index: index) else {
      return base
    }

    let filler = String(repeating: " long-text-payload", count: max(1, config.longTextBytes / 18))
    return "\(base)\(filler)"
  }

  private func title(index: Int, contentIndex: Int) -> String {
    "maccy-perf item-\(padded(index)) needle-\(padded(contentIndex))"
  }

  private func includesLongText(index: Int) -> Bool {
    config.longTextEvery > 0 && index % config.longTextEvery == 0
  }

  private func includesBinaryPayload(index: Int) -> Bool {
    config.binaryPayloadEvery > 0 && index % config.binaryPayloadEvery == 0
  }

  private func binaryPayload(seed: Int) -> Data {
    Data((0..<config.binaryPayloadBytes).map { UInt8(($0 + seed) % 256) })
  }

  private func padded(_ value: Int) -> String {
    String(format: "%06d", value)
  }
}

@MainActor
private final class InMemoryHistoryStore: LegacyHistoryStore {
  private var items: [HistoryItem]

  init(items: [HistoryItem]) {
    self.items = items
  }

  func loadAll() throws -> [HistoryItem] {
    items
  }

  func loadDuplicateCandidates(for item: HistoryItem) throws -> [HistoryItem] {
    items.filter { $0 !== item }
  }

  func insert(_ item: HistoryItem) throws {
    items.append(item)
  }

  func delete(_ item: HistoryItem) throws {
    items.removeAll { $0 === item }
  }

  func deleteUnpinned() throws {
    items.removeAll { $0.pin == nil }
  }

  func deleteAll() throws {
    items.removeAll()
  }

  func countItems() throws -> Int {
    items.count
  }

  func countContents() throws -> Int {
    items.reduce(0) { $0 + $1.contents.count }
  }
}

private struct BaselineMeasurement {
  let config: SyntheticHistoryConfig
  let operation: String
  let durationNanoseconds: UInt64
  let memoryDeltaBytes: Int64
  let outputCount: Int

  var durationMilliseconds: Double {
    Double(durationNanoseconds) / 1_000_000
  }
}

private enum BaselineReport {
  static func render(_ measurements: [BaselineMeasurement]) -> String {
    let csvHeader = [
      "items",
      "duplicate_rate",
      "long_text_every",
      "long_text_bytes",
      "binary_every",
      "binary_bytes",
      "operation",
      "duration_ms",
      "memory_delta_bytes",
      "output_count"
    ].joined(separator: ",")

    var lines = ["maccy_performance_baseline_csv", csvHeader]

    lines.append(contentsOf: measurements.map(csvLine))
    return lines.joined(separator: "\n")
  }

  private static func csvLine(_ measurement: BaselineMeasurement) -> String {
    let config = measurement.config
    let duration = String(format: "%.3f", measurement.durationMilliseconds)

    return [
      String(config.itemCount),
      String(config.duplicateRate),
      String(config.longTextEvery),
      String(config.longTextBytes),
      String(config.binaryPayloadEvery),
      String(config.binaryPayloadBytes),
      measurement.operation,
      duration,
      String(measurement.memoryDeltaBytes),
      String(measurement.outputCount)
    ].joined(separator: ",")
  }
}

private func residentMemoryBytes() -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

  let result = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }

  guard result == KERN_SUCCESS else {
    return 0
  }

  return UInt64(info.resident_size)
}
