// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  var items: [HistoryItemDecorator] = []
  var pasteStack: PasteStack?

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }
  var hasMoreRecentRows: Bool { searchQuery.isEmpty && nextRecentRowsCursor != nil }

  var searchQuery: String = "" {
    didSet {
      let query = searchQuery
      searchTask?.cancel()
      throttler.throttle { [self] in
        startSearch(query: query)
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private let historyStore: any LegacyHistoryStore

  @ObservationIgnored
  private let popupHistoryStore: any PopupHistoryStore

  @ObservationIgnored
  private var nextRecentRowsCursor: PopupHistoryPageCursor?

  @ObservationIgnored
  private var isLoadingMoreRecentRows = false

  @ObservationIgnored
  private var searchTask: Task<Void, Never>?

  @ObservationIgnored
  private var cachedPopupRowIDs = Set<String>()

  @ObservationIgnored
  private var popupRowsByMaterializedItemID: [ObjectIdentifier: PopupHistoryRow] = [:]

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // The distinction between `all` and `items` is the following:
  // - `all` stores all history items, even the ones that are currently hidden by a search
  // - `items` stores only visible history items, updated during a search
  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  init(
    historyStore: any LegacyHistoryStore = SwiftDataHistoryStore(),
    popupHistoryStore: (any PopupHistoryStore)? = nil
  ) {
    self.historyStore = historyStore
    self.popupHistoryStore = popupHistoryStore ??
      ArchiveDatabaseBootstrap.popupHistoryStoreIfEnabled() ??
      SwiftDataPopupHistoryStore(historyStore: historyStore)

    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    let page = try popupHistoryStore.loadInitialRows(recentLimit: Defaults[.popupRecentPageSize])
    popupRowsByMaterializedItemID.removeAll()
    let results = try materialize(page.rows)
    all = sorter.sort(results).map { HistoryItemDecorator($0) }
    items = all
    cachedPopupRowIDs = Set(page.rows.map(\.id))
    nextRecentRowsCursor = page.nextRecentCursor

    if !(popupHistoryStore is any PopupHistoryWriteStore) {
      limitHistorySize(to: Defaults[.size])
    }

    updateShortcuts()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  @discardableResult
  func loadMoreRecentRowsIfNeeded(after item: HistoryItemDecorator?) async -> Bool {
    guard shouldLoadMoreRecentRows(after: item) else { return false }
    return await loadMoreRecentRows()
  }

  @MainActor
  @discardableResult
  func loadMoreRecentRows() async -> Bool {
    guard !isLoadingMoreRecentRows,
          searchQuery.isEmpty,
          let cursor = nextRecentRowsCursor else {
      return false
    }

    isLoadingMoreRecentRows = true
    defer { isLoadingMoreRecentRows = false }

    do {
      let page = try popupHistoryStore.loadMoreRecentRows(after: cursor, limit: Defaults[.popupRecentPageSize])
      nextRecentRowsCursor = page.nextCursor
      let newRows = page.rows.filter { cachedPopupRowIDs.insert($0.id).inserted }
      let decorators = try materialize(newRows).map { HistoryItemDecorator($0) }
      appendRecentDecorators(decorators)
      return !decorators.isEmpty
    } catch {
      logger.error("Failed to load more recent rows: \(error.localizedDescription)")
      nextRecentRowsCursor = nil
      return false
    }
  }

  @MainActor
  private func shouldLoadMoreRecentRows(after item: HistoryItemDecorator?) -> Bool {
    guard searchQuery.isEmpty,
          nextRecentRowsCursor != nil,
          let item,
          let index = unpinnedItems.firstIndex(of: item) else {
      return false
    }

    return index >= max(unpinnedItems.count - 10, 0)
  }

  @MainActor
  private func materialize(_ rows: [PopupHistoryRow]) throws -> [HistoryItem] {
    try rows.map { row in
      let item = try popupHistoryStore.materialize(row)
      popupRowsByMaterializedItemID[ObjectIdentifier(item)] = row
      return item
    }
  }

  @MainActor
  private func appendRecentDecorators(_ decorators: [HistoryItemDecorator]) {
    guard !decorators.isEmpty else { return }

    let insertionIndex = all.lastIndex(where: \.isUnpinned).map { all.index(after: $0) } ??
      all.firstIndex(where: \.isPinned) ?? all.endIndex
    all.insert(contentsOf: decorators, at: insertionIndex)
    items = all

    updateUnpinnedShortcuts()
    AppState.shared.popup.needsResize = true
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    let unpinned = all.filter(\.isUnpinned)
    if unpinned.count >= maxSize {
      unpinned[maxSize...].forEach(delete)
    }
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    guard !(popupHistoryStore is any PopupHistoryWriteStore) else { return }

    logger.info("Inserting item with id '\(item.title)'")
    try historyStore.insert(item)
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if let writeStore = popupHistoryStore as? any PopupHistoryWriteStore {
      return addToPopupStore(item, writeStore: writeStore)
    }

    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        item.contents = existingHistoryItem.contents
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      try? historyStore.delete(existingHistoryItem)
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        all.remove(at: removedItemIndex)
      }
    } else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    limitHistorySize(to: Defaults[.size] - 1)

    sessionLog[Clipboard.shared.changeCount] = item

    var itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      // Keep pins in the same place.
      if let removedItemIndex {
        all.insert(itemDecorator, at: removedItemIndex)
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)

      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        all.insert(itemDecorator, at: index)
      }

      items = all
      updateUnpinnedShortcuts()
      AppState.shared.popup.needsResize = true
    }

    return itemDecorator
  }

  @MainActor
  private func addToPopupStore(
    _ item: HistoryItem,
    writeStore: any PopupHistoryWriteStore
  ) -> HistoryItemDecorator {
    do {
      let replacingRow = isModified(item).flatMap { popupRowsByMaterializedItemID[ObjectIdentifier($0)] }
      guard let result = try writeStore.upsert(item, replacing: replacingRow) else {
        return HistoryItemDecorator(item)
      }

      let materializedItem = try popupHistoryStore.materialize(result.row)
      if let existingIndex = all.firstIndex(where: { popupRow(for: $0)?.id == result.row.id }) {
        let existingItem = all.remove(at: existingIndex)
        popupRowsByMaterializedItemID.removeValue(forKey: ObjectIdentifier(existingItem.item))
      } else if result.inserted {
        Task {
          Notifier.notify(body: materializedItem.title, sound: .write)
        }
      }

      sessionLog[Clipboard.shared.changeCount] = materializedItem
      cachedPopupRowIDs.insert(result.row.id)
      let itemDecorator = HistoryItemDecorator(materializedItem)
      popupRowsByMaterializedItemID[ObjectIdentifier(materializedItem)] = result.row
      insertMaterializedDecorator(itemDecorator)
      return itemDecorator
    } catch {
      logger.error("Failed to write archive history item: \(error.localizedDescription)")
      return HistoryItemDecorator(item)
    }
  }

  @MainActor
  private func insertMaterializedDecorator(_ itemDecorator: HistoryItemDecorator) {
    if let pin = itemDecorator.item.pin {
      itemDecorator.shortcuts = KeyShortcut.create(character: pin)
    }

    let sortedItems = sorter.sort(all.map(\.item) + [itemDecorator.item])
    if let index = sortedItems.firstIndex(of: itemDecorator.item) {
      all.insert(itemDecorator, at: index)
    } else {
      all.insert(itemDecorator, at: 0)
    }

    items = all
    updateUnpinnedShortcuts()
    AppState.shared.popup.needsResize = true
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? historyStore.countItems()
      let historyContentCount = try? historyStore.countContents()
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      let unpinnedItems = all.filter(\.isUnpinned)
      unpinnedItems.forEach(cleanup)
      removeCachedRows(for: unpinnedItems)
      all.removeAll(where: \.isUnpinned)
      sessionLog.removeValues { $0.pin == nil }
      nextRecentRowsCursor = nil
      items = all

      try? popupHistoryStore.deleteUnpinned()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      popupRowsByMaterializedItemID.removeAll()
      cachedPopupRowIDs.removeAll()
      nextRecentRowsCursor = nil
      items = all

      try? popupHistoryStore.deleteAll()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    cleanup(item)
    withLogging("Removing history item") {
      if let row = popupRow(for: item) {
        try? popupHistoryStore.delete(row)
      } else {
        try? historyStore.delete(item.item)
      }
    }

    all.removeAll { $0 == item }
    items.removeAll { $0 == item }
    popupRowsByMaterializedItemID.removeValue(forKey: ObjectIdentifier(item.item))
    sessionLog.removeValues { $0 == item.item }

    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  @MainActor
  private func removeCachedRows(for items: [HistoryItemDecorator]) {
    for item in items {
      if let row = popupRowsByMaterializedItemID.removeValue(forKey: ObjectIdentifier(item.item)) {
        cachedPopupRowIDs.remove(row.id)
      }
    }
  }

  private func currentModifierFlags() -> NSEvent.ModifierFlags {
    return NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    let modifierFlags = currentModifierFlags()

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let modifierFlags = currentModifierFlags()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying \(item.item.title) from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let pasted = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted \(pasted.item.title)")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying \(item.item.title) from PasteStack. \(stack.items.count) items remaining in stack.")

    Task {
      if stack.modifierFlags.isEmpty {
        await Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          await Clipboard.shared.copy(item.item)
        case .paste:
          await Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          await Clipboard.shared.copy(item.item, removeFormatting: true)
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    let pin = item.item.pin == nil ? nextAvailablePin(excluding: item) : nil
    item.item.pin = pin
    if let row = popupRow(for: item) {
      try? popupHistoryStore.setPin(row, pin: pin)
    }

    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    }

    items = all

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  private func popupRow(for item: HistoryItemDecorator) -> PopupHistoryRow? {
    popupRowsByMaterializedItemID[ObjectIdentifier(item.item)]
  }

  private func nextAvailablePin(excluding item: HistoryItemDecorator) -> String {
    let assignedPins = Set(all.filter { $0 != item }.compactMap(\.item.pin))
    return HistoryItem.supportedPins.subtracting(assignedPins).sorted().first ?? ""
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    if let candidates = try? historyStore.loadDuplicateCandidates(for: item) {
      // Current duplicate semantics: exact match or stored superset, then modified pasteboard marker fallback.
      return candidates.first(where: { $0 == item || $0.supersedes(item) }) ?? isModified(item)
    }

    return item
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  private func startSearch(query: String) {
    searchTask?.cancel()
    searchTask = Task { [self] in
      await runSearch(query: query)
    }
  }

  private func runSearch(query: String) async {
    guard !Task.isCancelled else { return }

    if query.isEmpty {
      items = all
      finishSearch(query: query)
      return
    }

    guard let archiveSearchStore = popupHistoryStore as? any ArchiveSearchHistoryStore else {
      updateItems(search.search(string: query, within: all), query: query)
      finishSearch(query: query)
      return
    }

    do {
      let page = try await archiveSearchStore.search(ArchiveSearchRequest(
        query: query,
        mode: archiveSearchMode,
        limit: Defaults[.popupRecentPageSize]
      ))
      guard !Task.isCancelled, searchQuery == query else { return }

      let results = try await materialize(page.rows)
      guard !Task.isCancelled, searchQuery == query else { return }

      items = results.map { item in
        let decorator = HistoryItemDecorator(item)
        decorator.highlight(query, [])
        return decorator
      }
      updateUnpinnedShortcuts()
      finishSearch(query: query)
    } catch is CancellationError {
      return
    } catch {
      logger.error("Failed to search archive history: \(error.localizedDescription)")
    }
  }

  private var archiveSearchMode: ArchiveSearchMode {
    switch Defaults[.searchMode] {
    case .fuzzy:
      return .fuzzy
    case .regexp:
      return .regexp
    case .mixed:
      return .mixed
    default:
      return .exact
    }
  }

  private func updateItems(_ newItems: [Search.SearchResult], query: String) {
    guard searchQuery == query else { return }

    items = newItems.map { result in
      let item = result.object
      item.highlight(query, result.ranges)

      return item
    }

    updateUnpinnedShortcuts()
  }

  private func finishSearch(query: String) {
    guard searchQuery == query else { return }

    if query.isEmpty {
      AppState.shared.navigator.select(item: unpinnedItems.first)
    } else {
      AppState.shared.navigator.highlightFirst()
    }

    AppState.shared.popup.needsResize = true
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}
