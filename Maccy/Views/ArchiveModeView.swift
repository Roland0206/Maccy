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
        .padding()

      Divider()

      HStack(spacing: 0) {
        ArchiveModeResultsView(viewModel: viewModel)
          .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity)

        Divider()

        ArchiveModePreviewView(viewModel: viewModel)
          .frame(minWidth: 320, idealWidth: 380, maxWidth: .infinity)
      }
    }
    .frame(minWidth: 800, minHeight: 520)
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
    HStack(spacing: 12) {
      Text("Archive Mode")
        .font(.title2.weight(.semibold))

      TextField("Search archive", text: $viewModel.query)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 360)

      if viewModel.state == .loading || viewModel.isLoadingNextPage {
        ProgressView()
          .controlSize(.small)
      }

      Spacer()

      Button("Copy") {
        Task { await viewModel.copySelected() }
      }
      .disabled(!viewModel.canActOnSelection)

      Button("Paste") {
        Task { await viewModel.copySelected(paste: true) }
      }
      .disabled(!viewModel.canActOnSelection)

      Button(viewModel.selectedRow?.isPinned == true ? "Unpin" : "Pin") {
        Task { await viewModel.togglePinSelected() }
      }
      .disabled(!viewModel.canActOnSelection)

      Button("Delete", role: .destructive) {
        Task { await viewModel.deleteSelected() }
      }
      .disabled(!viewModel.canActOnSelection)
    }
  }
}

private struct ArchiveModeResultsView: View {
  @Bindable var viewModel: ArchiveModeViewModel

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $viewModel.selectedRowID) {
        ForEach(viewModel.rows) { row in
          ArchiveModeRowView(row: row)
            .tag(row.id)
        }
      }

      Divider()

      ArchiveModeStatusView(viewModel: viewModel)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
  }
}

private struct ArchiveModeRowView: View {
  let row: PopupHistoryRow

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Image(systemName: row.isPinned ? "pin.fill" : "clock")
          .foregroundStyle(row.isPinned ? Color.accentColor : Color.secondary)
          .frame(width: 14)

        Text(row.title.isEmpty ? "Untitled" : row.title)
          .lineLimit(1)
          .truncationMode(.tail)

        Spacer()

        Text(row.lastCopiedAt, style: .date)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        if let bundle = row.applicationBundleIdentifier, !bundle.isEmpty {
          Label(bundle, systemImage: "app")
        }

        Label("\(row.numberOfCopies)", systemImage: "number")

        ForEach(row.contents, id: \.type) { content in
          Label(content.type, systemImage: content.hasPayload ? "doc" : "doc.badge.questionmark")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
    .padding(.vertical, 4)
  }
}

private struct ArchiveModeStatusView: View {
  @Bindable var viewModel: ArchiveModeViewModel

  var body: some View {
    HStack {
      switch viewModel.state {
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      case .empty:
        Label("No archive results", systemImage: "tray")
          .foregroundStyle(.secondary)
      default:
        Text("\(viewModel.rows.count) loaded")
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button("Load More") {
        Task { await viewModel.loadNextPage() }
      }
      .disabled(!viewModel.hasMore || viewModel.isLoadingNextPage)
    }
    .controlSize(.small)
  }
}

private struct ArchiveModePreviewView: View {
  @Bindable var viewModel: ArchiveModeViewModel

  var body: some View {
    Group {
      if viewModel.isLoadingPreview {
        VStack(spacing: 12) {
          ProgressView()
          Text("Loading preview…")
            .foregroundStyle(.secondary)
        }
      } else if let item = viewModel.selectedItem {
        PreviewItemView(item: item)
          .padding()
      } else {
        VStack(spacing: 12) {
          Image(systemName: "sidebar.right")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text("Select an item to preview")
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  ArchiveModeView()
}
