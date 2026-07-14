import SwiftUI

/// Renders a unified diff (as produced by `git diff --no-color`) with
/// per-line coloring. No syntax highlighting — this is git's own diff
/// format, not markdown.
struct DiffView: View {
  let diff: PageDiff

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if diff.text.isEmpty {
        ContentUnavailableView(
          "No changes", systemImage: "checkmark.circle",
          description: Text("This revision matches the current version."))
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
              Text(line.text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(line.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(12)
        }
      }
    }
    .frame(minWidth: 480, minHeight: 360)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(diff.path)
        .font(.headline)
      Text("Since \(diff.revision.date.formatted(date: .abbreviated, time: .shortened)) — \(diff.revision.subject)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private struct Line {
    var text: String
    var color: Color
  }

  private var lines: [Line] {
    diff.text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
      let text = String(raw)
      switch true {
      case text.hasPrefix("+++"), text.hasPrefix("---"):
        return Line(text: text, color: .secondary)
      case text.hasPrefix("+"):
        return Line(text: text, color: .green)
      case text.hasPrefix("-"):
        return Line(text: text, color: .red)
      case text.hasPrefix("@@"):
        return Line(text: text, color: .cyan)
      case text.hasPrefix("diff "), text.hasPrefix("index "):
        return Line(text: text, color: .secondary)
      default:
        return Line(text: text, color: .primary)
      }
    }
  }
}
