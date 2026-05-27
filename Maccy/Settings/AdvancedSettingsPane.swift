import AppKit
import SwiftUI
import Defaults
import UniformTypeIdentifiers

struct AdvancedSettingsPane: View {
  @State private var importExportStatus: String?
  @State private var importExportFailed = false

  var body: some View {
    VStack(alignment: .leading) {
      Defaults.Toggle(key: .ignoreEvents) {
        Text("TurnOff", tableName: "AdvancedSettings")
      }
      Text("TurnOffDescription", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      Text("TurnOffShellScript", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .font(.system(size: 11, design: .monospaced))
        .controlSize(.small)
        .padding(.vertical, 2)
      Text("TurnOffViaMenuIconDescription", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      Text("TurnOffNextShellScript", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .font(.system(size: 11, design: .monospaced))
        .controlSize(.small)
        .padding(.vertical, 2)

      Divider()

      Defaults.Toggle(key: .clearOnQuit) {
        Text("ClearHistoryOnQuit", tableName: "AdvancedSettings")
      }.help(Text("ClearHistoryOnQuitTooltip", tableName: "AdvancedSettings"))

      Defaults.Toggle(key: .clearSystemClipboard) {
        Text("ClearSystemClipboard", tableName: "AdvancedSettings")
      }.help(Text("ClearSystemClipboardTooltip", tableName: "AdvancedSettings"))

      Divider()

      Text("ImportExport", tableName: "AdvancedSettings")
        .font(.headline)
      HStack {
        Button(action: importOldMaccyHistory) {
          Text("ImportOldMaccyHistory", tableName: "AdvancedSettings")
        }
        Button(action: exportPortableArchive) {
          Text("ExportPortableArchive", tableName: "AdvancedSettings")
        }
      }
      Text("ImportExportDescription", tableName: "AdvancedSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      if let importExportStatus {
        Text(importExportStatus)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(importExportFailed ? .red : .green)
          .controlSize(.small)
      }
    }
    .frame(minWidth: 350, maxWidth: 450)
    .padding()
  }

  private func importOldMaccyHistory() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
    panel.message = String(localized: "ChooseOldMaccyHistory", table: "AdvancedSettings")

    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let database = try ArchiveDatabase.open()
      let report = try OldMaccyHistoryImporter().importHistory(from: url, into: database)
      importExportFailed = report.errorCount > 0
      importExportStatus = "Imported \(report.itemsImported) old Maccy items (\(report.representationsImported) representations). Errors: \(report.errorCount)."
    } catch {
      importExportFailed = true
      importExportStatus = error.localizedDescription
    }
  }

  private func exportPortableArchive() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: ArchivePortableExporter.fileExtension) ?? .folder]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = ArchivePortableExporter.defaultArchiveName()
    panel.message = String(localized: "ChoosePortableArchiveDestination", table: "AdvancedSettings")

    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let database = try ArchiveDatabase.open()
      let exportedURL = try ArchivePortableExporter().export(
        database: database,
        databaseURL: ArchiveDatabase.defaultURL,
        payloadStore: ArchivePayloadStore(),
        to: url
      )
      importExportFailed = false
      importExportStatus = "Exported portable archive to \(exportedURL.path)."
    } catch {
      importExportFailed = true
      importExportStatus = error.localizedDescription
    }
  }
}

#Preview {
  AdvancedSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
