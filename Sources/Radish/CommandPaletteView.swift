import AppKit
import RadishCore
import SwiftUI

/// The Go to Page palette: a search field over a fuzzy-ranked list of page
/// paths. Matching runs in `rd-core` (`fuzzyMatch`); this view only renders
/// results and handles the keyboard.
///
/// Keys: ↑/↓ (or ⌃P/⌃N) move the highlight, ⏎ opens it, ⎋ closes.
struct CommandPaletteView: View {
  /// Candidate paths, most recently modified first. An empty query lists them
  /// in this order, and equal fuzzy scores keep it.
  let paths: [String]
  let onOpen: (String) -> Void
  let onDismiss: () -> Void

  @State private var query = ""
  @State private var results: [FuzzyMatch] = []
  @State private var highlighted = 0
  @FocusState private var fieldFocused: Bool
  @State private var window: NSWindow?
  @State private var keyMonitor: Any?

  private static let limit: UInt32 = 50
  private static let rowHeight: CGFloat = 40
  private static let maxVisibleRows: CGFloat = 8

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Go to page", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($fieldFocused)
          .onSubmit(openHighlighted)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Divider()
      resultList
    }
    .frame(width: 520)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(.separator)
    }
    .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
    .background(WindowAccessor { window = $0 })
    .onAppear {
      fieldFocused = true
      installKeyMonitor()
    }
    .onDisappear(perform: removeKeyMonitor)
    .onChange(of: query, initial: true) { search() }
    .onChange(of: paths) { search() }
  }

  @ViewBuilder
  private var resultList: some View {
    if results.isEmpty {
      Text(paths.isEmpty ? "No pages" : "No matching pages")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: Self.rowHeight)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.path) { index, match in
              row(match, isHighlighted: index == highlighted)
                .id(index)
                .onTapGesture { onOpen(match.path) }
                .onHover { if $0 { highlighted = index } }
            }
          }
          .padding(6)
        }
        .frame(
          height: min(CGFloat(results.count), Self.maxVisibleRows) * Self.rowHeight + 12)
        .onChange(of: highlighted) { _, index in
          proxy.scrollTo(index)
        }
      }
    }
  }

  private func row(_ match: FuzzyMatch, isHighlighted: Bool) -> some View {
    let scalars = Array(match.path.unicodeScalars)
    let nameStart = (scalars.lastIndex(of: "/") ?? -1) + 1
    let matched = Set(match.indices.map(Int.init))
    return HStack(spacing: 8) {
      Image(systemName: "doc.text")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(Self.emphasize(scalars, nameStart..<scalars.count, matched))
          .lineLimit(1)
        if nameStart > 0 {
          Text(Self.emphasize(scalars, 0..<(nameStart - 1), matched))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .frame(height: Self.rowHeight)
    .background(
      isHighlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(Rectangle())
  }

  /// `scalars[range]` as text, with the scalars at `matched` offsets in bold.
  /// Offsets count Unicode scalars from the start of the whole path, matching
  /// `FuzzyMatch.indices`.
  private static func emphasize(
    _ scalars: [Unicode.Scalar], _ range: Range<Int>, _ matched: Set<Int>
  ) -> AttributedString {
    var result = AttributedString()
    for offset in range {
      var piece = AttributedString(String(scalars[offset]))
      if matched.contains(offset) {
        piece.inlinePresentationIntent = .stronglyEmphasized
      }
      result += piece
    }
    return result
  }

  private func search() {
    results = fuzzyMatch(query: query, paths: paths, limit: Self.limit)
    highlighted = 0
  }

  /// Handles the palette's navigation keys ahead of the text field. The
  /// field editor behind a `TextField` consumes ↑, ↓, ⌃P, and ⌃N as cursor
  /// movement, so `.onKeyPress` on the field never sees them. The monitor
  /// only acts on events for this palette's window.
  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.window === window else { return event }
      let modifiers = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
      let key = event.charactersIgnoringModifiers
      switch (event.keyCode, modifiers) {
      case (126, []): move(-1)
      case (125, []): move(1)
      case (53, []): onDismiss()
      case (_, .control) where key == "p": move(-1)
      case (_, .control) where key == "n": move(1)
      default: return event
      }
      return nil
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }

  private func move(_ step: Int) {
    guard !results.isEmpty else { return }
    highlighted = (highlighted + step + results.count) % results.count
  }

  private func openHighlighted() {
    guard results.indices.contains(highlighted) else { return }
    onOpen(results[highlighted].path)
  }
}
