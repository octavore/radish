import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
  private(set) var repo: URL?
  private(set) var pages: [Page] = []
  private(set) var tree: [DocNode] = []
  private(set) var status: String = ""
  /// Git identity of the selected page, shown in the inspector. Nil for a
  /// folder row, which is a path prefix rather than a stored object.
  private(set) var info: PageInfo?
  var showInspector = true
  var errorMessage: String?

  /// Set when the user asks to diff the current page against a past revision;
  /// presenting it drives a sheet in ContentView.
  var diff: PageDiff?

  /// The editor's document. Its *string content is raw markdown source* — the
  /// editor highlights the source itself, so this must round-trip verbatim.
  /// Never construct it with `AttributedString(markdown:)`: that parses the
  /// syntax away, and a load→save cycle would rewrite every page into plain
  /// prose and fill git history with phantom diffs.
  var text = AttributedString("")
  private(set) var isDirty = false

  var selection: Page.ID? {
    didSet {
      guard selection != oldValue else { return }
      Task { await loadSelection() }
    }
  }

  private var store: DocStore?
  private static let repoKey = "repoURL"

  init() {
    if let saved = UserDefaults.standard.string(forKey: Self.repoKey) {
      let url = URL(fileURLWithPath: saved)
      if Git.isRepository(url) { open(url) }
    }
  }

  var source: String {
    get { String(text.characters) }
    set { text = AttributedString(newValue) }
  }

  /// Binding handed to the editor. Edits mark the document dirty; loads from
  /// git go through `setSource(fromDisk:)` and do not.
  var editorText: Binding<AttributedString> {
    Binding(
      get: { self.text },
      set: { new in
        guard new != self.text else { return }
        self.text = new
        self.isDirty = true
      })
  }

  /// Prompts for a repository and opens it in this window, replacing whatever
  /// was open. ⌘N (or a new tab) gets you a second window with its own repo.
  func chooseRepo() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a git repository."
    panel.directoryURL = repo
    guard panel.runModal() == .OK, let url = panel.url else { return }
    open(url)
  }

  func open(_ url: URL) {
    guard Git.isRepository(url) else {
      errorMessage = "\(url.lastPathComponent) is not a git repository."
      return
    }

    // Clear the outgoing repo's state before the new one loads, so a stale page
    // can't linger in the editor while the new tree is read.
    selection = nil
    pages = []
    tree = []
    info = nil
    text = AttributedString("")
    isDirty = false

    repo = url
    store = DocStore(root: url)
    UserDefaults.standard.set(url.path, forKey: Self.repoKey)
    Task { await refresh() }
  }

  func refresh() async {
    guard let store else { return }
    do {
      let found = try await run { try store.listPages() }
      pages = found
      tree = DocTree.build(found)
      if let selection, !found.contains(where: { $0.id == selection }) {
        self.selection = nil
      }
      if selection == nil, let first = found.first { selection = first.id }
      status = found.isEmpty ? "No pages yet" : "\(found.count) page(s)"
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func save() async {
    guard let store, let path = selection else { return }
    let content = source
    do {
      try await run { try store.write(path: path, content: content) }
      isDirty = false
      status = "Saved \(path)"
      // The write minted a new blob and advanced the ref, so the inspector's
      // OIDs are now stale.
      info = try await run { try store.info(for: path) }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func createPage(path rawPath: String) async {
    guard let store else { return }
    let trimmed = rawPath.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    let path = trimmed.hasSuffix(".md") ? trimmed : trimmed + ".md"

    do {
      try await run {
        try store.write(
          path: path, content: "# \(Page(path: path).title)\n\n", message: "docs: create \(path)")
      }
      await refresh()
      selection = path
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func deleteSelection() async {
    guard let store, let path = selection else { return }
    do {
      try await run { try store.delete(path: path) }
      selection = nil
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Selecting a folder row shows nothing: a folder is a path prefix shared by
  /// pages, not a stored object, so there is neither content nor an OID for it.
  private func loadSelection() async {
    guard let store, let path = selection, pages.contains(where: { $0.path == path }) else {
      text = AttributedString("")
      info = nil
      isDirty = false
      return
    }
    do {
      let content = try await run { try store.read(path) }
      text = AttributedString(content)
      isDirty = false
      info = try await run { try store.info(for: path) }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Diffs the current page's content at `revision` against its current tip.
  func showDiff(against revision: Revision) async {
    guard let store, let path = selection else { return }
    do {
      let text = try await run { try store.diff(path: path, from: revision.id) }
      diff = PageDiff(path: path, revision: revision, text: text)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Runs blocking git work off the main actor.
  private func run<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
  }
}
