import SwiftUI

struct ArchiveModeView: View {
  @State private var viewModel: ArchiveModeViewModel

  @MainActor
  init(viewModel: ArchiveModeViewModel? = nil) {
    _viewModel = State(initialValue: viewModel ?? ArchiveModeViewModel())
  }

  var body: some View {
    VStack(spacing: 0) {
      ArchiveModeToolbarView(viewModel: viewModel)

      Divider()

      HStack(spacing: 0) {
        ArchiveModeResultsView(viewModel: viewModel)
          .frame(minWidth: 440, idealWidth: 540, maxWidth: .infinity)

        Divider()

        ArchiveModePreviewView(viewModel: viewModel)
          .frame(minWidth: 320, idealWidth: 400, maxWidth: .infinity)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .frame(minWidth: 820, minHeight: 540)
    .task {
      await viewModel.loadFirstPage()
    }
    .task(id: viewModel.query) {
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      await viewModel.loadFirstPage()
    }
    .task(id: viewModel.selectedRowID) {
      await viewModel.loadSelectedPreview()
    }
  }
}

private struct ArchiveModeToolbarView: View {
  @Bindable var viewModel: ArchiveModeViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Archive Mode")
            .font(.title2.weight(.semibold))
          Text("Browse deep clipboard history without loading the full corpus.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        ArchiveModeActionBar(viewModel: viewModel)
      }

      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search archive", text: $viewModel.query)
          .textFieldStyle(.plain)
          .disableAutocorrection(true)
        if !viewModel.query.isEmpty {
          Button {
            viewModel.query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 7)
      .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .padding(16)
  }
}

private struct ArchiveModeActionBar: View {
  @Bindable var viewModel: ArchiveModeViewModel

  var body: some View {
    HStack(spacing: 8) {
      if viewModel.state == .loading || viewModel.isLoadingNextPage {
        ProgressView()
          .controlSize(.small)
      }

      Button {
        Task { await viewModel.copySelected() }
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .disabled(!viewModel.canActOnSelection)

      Button {
        Task { await viewModel.copySelected(paste: true) }
      } label: {
        Label("Paste", systemImage: "arrow.turn.down.left")
      }
      .disabled(!viewModel.canActOnSelection)

      Button {
        Task { await viewModel.togglePinSelected() }
      } label: {
        Label(viewModel.selectedRow?.isPinned == true ? "Unpin" : "Pin", systemImage: "pin")
      }
      .disabled(!viewModel.canActOnSelection)

      Button(role: .destructive) {
        Task { await viewModel.deleteSelected() }
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .disabled(!viewModel.canActOnSelection)
    }
    .labelStyle(.iconOnly)
    .controlSize(.small)
  }
}

private struct ArchiveModeResultsView: View {
  @Bindable var viewModel: ArchiveModeViewModel

  var body: some View {
    VStack(spacing: 0) {
      ArchiveModeResultsHeaderView(viewModel: viewModel)

      ZStack {
        List(selection: $viewModel.selectedRowID) {
          ForEach(viewModel.rows) { row in
            ArchiveModeRowView(row: row)
              .tag(row.id)
          }
        }
        .listStyle(.inset)

        if viewModel.state == .loading && viewModel.rows.isEmpty {
          ArchiveModeLoadingView(title: viewModel.isSearching ? "Searching archive…" : "Loading archive…")
        } else if viewModel.state == .empty {
          ArchiveModeEmptyView(title: viewModel.emptyStateTitle, message: viewModel.emptyStateDescription)
        } else if case .failed(let message) = viewModel.state {
          ArchiveModeEmptyView(title: "Archive unavailable", message: message, systemImage: "exclamationmark.triangle")
        }
      }

      Divider()

      ArchiveModeStatusView(viewModel: viewModel)
    }
  }
}

private struct ArchiveModeResultsHeaderView: View {
  @Bindable var viewModel: ArchiveModeViewModel

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(viewModel.modeTitle)
          .font(.headline)
        Text(viewModel.isSearching ? "Bounded archive search page" : "Pinned items followed by recent pages")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Text("\(viewModel.rows.count) loaded")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor))
  }
}

private struct ArchiveModeRowView: View {
  let row: PopupHistoryRow

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Label(row.isPinned ? "Pinned" : "Recent", systemImage: row.isPinned ? "pin.fill" : "clock")
          .labelStyle(.iconOnly)
          .foregroundStyle(row.isPinned ? Color.accentColor : Color.secondary)
          .frame(width: 16)

        Text(row.title.isEmpty ? "Untitled" : row.title)
          .font(.body.weight(.medium))
          .lineLimit(1)
          .truncationMode(.tail)

        Spacer(minLength: 8)

        Text(row.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 6) {
        if let bundle = row.applicationBundleIdentifier, !bundle.isEmpty {
          ArchiveModeBadge(systemImage: "app", text: bundle)
        }

        ArchiveModeBadge(systemImage: "number", text: "\(row.numberOfCopies)")

        if row.isPinned, let pin = row.pin {
          ArchiveModeBadge(systemImage: "keyboard", text: pin.uppercased())
        }

        ForEach(row.contents.indices, id: \.self) { index in
          let content = row.contents[index]
          ArchiveModeBadge(
            systemImage: content.hasPayload ? "doc" : "doc.badge.questionmark",
            text: content.type
          )
        }
      }
      .lineLimit(1)
    }
    .padding(.vertical, 6)
  }
}

private struct ArchiveModeBadge: View {
  let systemImage: String
  let text: String

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(.quaternary.opacity(0.8), in: Capsule())
  }
}

private struct ArchiveModeStatusView: View {
  @Bindable var viewModel: ArchiveModeViewModel

  var body: some View {
    HStack(spacing: 10) {
      if viewModel.isLoadingNextPage {
        ProgressView()
          .controlSize(.small)
      }

      Text(statusText)
        .foregroundStyle(.secondary)

      Spacer()

      Button(viewModel.isLoadingNextPage ? "Loading…" : "Load More") {
        Task { await viewModel.loadNextPage() }
      }
      .disabled(!viewModel.hasMore || viewModel.isLoadingNextPage || viewModel.state == .loading)
    }
    .font(.caption)
    .controlSize(.small)
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var statusText: String {
    if viewModel.hasMore {
      return "Page bounded. More results available."
    }
    return "End of current result set."
  }
}

private struct ArchiveModePreviewView: View {
  @Bindable var viewModel: ArchiveModeViewModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Preview")
          .font(.headline)
        Spacer()
        if viewModel.isLoadingPreview {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(Color(nsColor: .controlBackgroundColor))

      ZStack {
        if viewModel.isLoadingPreview {
          ArchiveModeLoadingView(title: "Loading selected item…")
        } else if let item = viewModel.selectedItem {
          PreviewItemView(item: item)
            .padding(16)
        } else {
          ArchiveModeEmptyView(
            title: "Select an item",
            message: "Payload bytes load only after selection.",
            systemImage: "sidebar.right"
          )
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ArchiveModeLoadingView: View {
  let title: String

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ArchiveModeEmptyView: View {
  let title: String
  let message: String
  var systemImage = "tray"

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 34, weight: .regular))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 280)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  ArchiveModeView()
}
