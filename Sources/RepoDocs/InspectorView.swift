import SwiftUI

/// Shows where the selected page actually lives in git. The point is to make
/// the storage model legible: every value here is one you can paste straight
/// into `git cat-file -p` and get the same bytes back.
struct InspectorView: View {
  let info: PageInfo?
  var onDiff: (Revision) -> Void = { _ in }

  var body: some View {
    Group {
      if let info {
        Form {
          Section("Location") {
            row("Ref", info.ref, mono: true)
            row("Path", info.path, mono: true)
          }

          Section("Objects") {
            oid("Blob", info.blob)
            oid("Ref tip", info.tip)
            row("Size", ByteCountFormatter.string(fromByteCount: Int64(info.byteCount), countStyle: .file))
          }

          Section("History") {
            row("Revisions", "\(info.revisions.count)")
            if let modified = info.lastModified {
              row("Last saved", modified.formatted(date: .abbreviated, time: .shortened))
            }
            ForEach(info.revisions.prefix(5)) { revision in
              Button {
                onDiff(revision)
              } label: {
                HStack(alignment: .firstTextBaseline) {
                  Text(String(revision.id.prefix(7)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                  Text(revision.subject)
                    .font(.caption)
                    .lineLimit(1)
                  Spacer()
                  Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .help("Diff against the current version")
            }
          }
        }
        .formStyle(.grouped)
      } else {
        ContentUnavailableView(
          "No page selected", systemImage: "info.circle",
          description: Text("Folders are path prefixes, not stored objects — they have no OID."))
      }
    }
    .textSelection(.enabled)
  }

  private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
    LabeledContent(label) {
      Text(value)
        .font(mono ? .system(.body, design: .monospaced) : .body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }

  /// Abbreviates an OID the way git does, but keeps the full value selectable
  /// so it can be copied out to a terminal.
  private func oid(_ label: String, _ value: String) -> some View {
    LabeledContent(label) {
      Text(value.isEmpty ? "—" : String(value.prefix(10)))
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(.secondary)
        .help(value)
    }
  }
}
