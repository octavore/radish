import AppKit
import Foundation
import RadishCore
import SwiftUI

@MainActor
@Observable
final class AppModel {
  private(set) var repo: URL?
  private(set) var pages: [Page] = []
  private(set) var tree: [DocNode] = []
  /// Folders created via the sidebar's "New Folder" but not yet holding a
  /// page; see `createFolder`. Client-side only; lost on refresh/reopen.
  private(set) var pendingFolders: Set<String> = []
  private(set) var status: String = ""
  /// Git identity of the selected page, shown in the inspector. Nil for a
  /// folder row, which is a path prefix rather than a stored object.
  private(set) var info: PageInfo?
  /// Every page path, most recently modified first. The Go to Page palette
  /// lists these for an empty query and passes them to `fuzzyMatch`, which
  /// keeps this order between equal scores.
  private(set) var recentPaths: [String] = []
  /// Visibility of the right sidebar. Persisted across launches.
  var showInspector = UserDefaults.standard.object(forKey: AppModel.showInspectorKey) as? Bool ?? true {
    didSet { UserDefaults.standard.set(showInspector, forKey: Self.showInspectorKey) }
  }
  /// Visibility of the left sidebar. Persisted across launches.
  var showSidebar = UserDefaults.standard.object(forKey: AppModel.showSidebarKey) as? Bool ?? true {
    didSet { UserDefaults.standard.set(showSidebar, forKey: Self.showSidebarKey) }
  }
  /// Sidebars that were visible when `toggleSidebars` last hid them.
  private var hiddenSidebars: (left: Bool, right: Bool)?
  /// IDs of the folder rows expanded in the left sidebar.
  var expandedFolders: Set<String> = []
  var showPalette = false
  var errorMessage: String?

  /// Set when the user asks to diff the current page against a past revision;
  /// presenting it drives a sheet in ContentView.
  var diff: PageDiff?

  /// The editor's document: raw markdown source, verbatim. The editor
  /// highlights this string itself, so it must round-trip exactly. A
  /// load/save cycle must never rewrite it, or git history accumulates
  /// diffs that change nothing.
  var text = ""
  private(set) var isDirty = false

  var selection: Page.ID? {
    didSet {
      guard selection != oldValue else { return }
      Task { await loadSelection() }
    }
  }

  private var store: DocStore?
  private var openGeneration = 0
  private static let repoKey = "repoURL"
  private static let showInspectorKey = "showInspector"
  private static let showSidebarKey = "showSidebar"

  /// Hide every visible sidebar. If none is visible, restore the sidebars
  /// hidden last time, or both if there are none.
  func toggleSidebars() {
    if showSidebar || showInspector {
      hiddenSidebars = (showSidebar, showInspector)
      showSidebar = false
      showInspector = false
    } else {
      let previous = hiddenSidebars ?? (true, true)
      showSidebar = previous.left
      showInspector = previous.right
    }
  }

  /// Reopens the repository from the last session. Kept out of `init` on
  /// purpose: `init` runs every time SwiftUI re-creates the owning view, and a
  /// git call (or any observable mutation) there feeds back into the view graph
  /// and spins. A view calls this once from `.task`.
  func restoreLastRepo() async {
    guard repo == nil, store == nil,
      let saved = UserDefaults.standard.string(forKey: Self.repoKey)
    else { return }
    // Another window already holds this repo (a second window from ⌘N, say).
    // Leave this one on the empty state rather than opening a duplicate.
    guard !AppWindows.openRepos.contains(saved) else { return }
    let url = URL(fileURLWithPath: saved)
    let generation = openGeneration
    let isRepo = (try? await run { isRepository(path: url.path) }) ?? false
    // An `open` that started while the check ran (an `rd open` URL that
    // arrived in this window) wins over the saved repo.
    guard isRepo, openGeneration == generation else { return }
    await open(url)
  }

  /// Resolves `url` to the top level of its git repository, matching the path
  /// `rd open` sends. Returns nil when `url` isn't inside a repo.
  func repoRoot(for url: URL) async -> URL? {
    let path = url.path
    let resolved = (try? await run { discoverRepository(path: path) }) ?? nil
    return resolved.map { URL(fileURLWithPath: $0) }
  }

  /// Brings an existing window for `url`'s repo to the front, when one is open
  /// and it isn't this window. Returns true when it did, so the caller can
  /// dismiss the redundant window it was about to fill.
  func focusIfOpenElsewhere(_ url: URL) async -> Bool {
    guard let root = await repoRoot(for: url), root.path != repo?.path else {
      return false
    }
    return AppWindows.openRepos.focus(root.path)
  }

  /// Binding handed to the editor. Edits mark the document dirty; loads from
  /// git go through `loadSelection()` and do not.
  var editorText: Binding<String> {
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
    Task {
      if await focusIfOpenElsewhere(url) { return }
      await open(url)
    }
  }

  /// Opens `url` as the window's repository. The path is first resolved to the
  /// repo's top level, so a subdirectory or symlinked path still keys the window
  /// by the same canonical path `rd open` uses. The `DocStore` construction
  /// shells out to git, so it runs off the main actor; everything after it is
  /// main-actor state assignment.
  func open(_ url: URL) async {
    // Only the most recent call may apply its result. A last-session restore
    // and an `rd open` URL can overlap in one window, and mixing their state
    // would pair one repo's pages with the other's store.
    openGeneration += 1
    let generation = openGeneration
    let root = await repoRoot(for: url) ?? url
    guard generation == openGeneration else { return }
    let opened: DocStore
    do {
      opened = try await run { try DocStore(root: root.path) }
    } catch {
      if generation == openGeneration { errorMessage = errorText(error) }
      return
    }
    guard generation == openGeneration else { return }

    // Clear the outgoing repo's state before the new one loads, so a stale page
    // can't linger in the editor while the new tree is read.
    selection = nil
    pages = []
    tree = []
    recentPaths = []
    showPalette = false
    pendingFolders = []
    info = nil
    text = ""
    isDirty = false

    repo = root
    store = opened
    UserDefaults.standard.set(root.path, forKey: Self.repoKey)
    await refresh()
    if let page = AppWindows.openRepos.takePendingPage(for: root.path) {
      selectPage(page)
    }
  }

  /// Select `path` if the repo has that page.
  func selectPage(_ path: String) {
    guard pages.contains(where: { $0.path == path }) else { return }
    showPalette = false
    showSidebar = true
    reveal(path)
    selection = path
  }

  /// Expand every folder above `path` in the sidebar.
  func reveal(_ path: String) {
    let parts = path.split(separator: "/").dropLast()
    var prefix = ""
    for part in parts {
      prefix += "\(part)/"
      expandedFolders.insert("folder:\(prefix)")
    }
  }

  func refresh() async {
    guard let store else { return }
    do {
      let (found, modified) = try await run {
        (try store.listPages(), try store.lastModifiedTimes())
      }
      // A newer `open` may have swapped the store while this listing ran.
      guard store === self.store else { return }
      pages = found
      recentPaths = found.map(\.path).sorted {
        let (a, b) = (modified[$0] ?? .distantPast, modified[$1] ?? .distantPast)
        return a != b ? a > b : $0 < $1
      }
      tree = buildTree(pages: found, pendingFolders: Array(pendingFolders))
      if let selection, !found.contains(where: { $0.id == selection }) {
        self.selection = nil
      }
      if selection == nil, let first = found.first { selection = first.id }
      status = found.isEmpty ? "No pages yet" : "\(found.count) page(s)"
    } catch {
      guard store === self.store else { return }
      errorMessage = errorText(error)
    }
  }

  /// Reread the page list and the selected page. Unsaved edits are kept.
  func reload() async {
    await refresh()
    if !isDirty { await loadSelection() }
  }

  func save() async {
    guard let store, let path = selection else { return }
    let content = text
    do {
      try await run { try store.write(path: path, content: content, message: nil) }
      isDirty = false
      status = "Saved \(path)"
      // The write minted a new blob and advanced the ref, so the inspector's
      // OIDs are now stale.
      info = try await run { try store.info(path: path) }
    } catch {
      errorMessage = errorText(error)
    }
  }

  /// Reformats the editor buffer with rumdl, through the same `DocStore.reformat`
  /// entry point `rd fmt` uses (so config resolution matches). It rewrites the
  /// in-memory `text` and marks the document dirty, so the result is reviewed in
  /// the editor and written by the normal save path rather than committed
  /// straight to git.
  func formatDocument() async {
    guard let store, selection != nil else { return }
    let current = text
    do {
      let formatted = try await run { try store.reformat(content: current) }
      // The user may have typed while rumdl ran; don't clobber that.
      guard text == current else { return }
      guard formatted != current else {
        status = "Already formatted"
        return
      }
      text = formatted
      isDirty = true
      status = "Reformatted"
    } catch {
      errorMessage = errorText(error)
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
          path: path, content: "# \(pageTitle(path: path))\n\n",
          message: "docs: create \(path)")
      }
      await refresh()
      selection = path
    } catch {
      errorMessage = errorText(error)
    }
  }

  /// Adds a folder to the sidebar without writing anything to git. The
  /// store has no folder objects (see `tree.rs`), so an empty folder cannot
  /// be persisted. This seeds `pendingFolders`, which `buildTree` folds into
  /// the tree; the folder becomes real when a page is created inside it, and
  /// disappears if the repo is refreshed or reopened before that happens.
  func createFolder(path rawPath: String) {
    let trimmed = rawPath
      .trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty else { return }
    pendingFolders.insert(trimmed + "/")
    tree = buildTree(pages: pages, pendingFolders: Array(pendingFolders))
  }

  /// Imports existing markdown files already sitting in the repo's working
  /// tree (or elsewhere on disk) into the page store. Directories are walked
  /// recursively for `.md` files; a file's page path is its path relative to
  /// the repo root, so an import round-trips back to the same tree shape.
  /// Reading is plain `FileManager`/`String(contentsOf:)` off the working
  /// tree; the store write goes through the usual §1 plumbing, so this never
  /// touches the index or `HEAD`.
  func importPaths(_ urls: [URL]) async {
    guard let store, let repoRoot = repo else { return }
    do {
      let count = try await run { () -> Int in
        let files = Self.collectMarkdownFiles(urls)
        for file in files {
          let relative = Self.relativePath(for: file, in: repoRoot)
          let content = try String(contentsOf: file, encoding: .utf8)
          try store.write(
            path: relative, content: content, message: "docs: import \(relative)")
        }
        return files.count
      }
      guard count > 0 else {
        errorMessage = "No markdown files found to import."
        return
      }
      await refresh()
      status = "Imported \(count) page(s)"
    } catch {
      errorMessage = errorText(error)
    }
  }

  nonisolated private static func collectMarkdownFiles(_ urls: [URL]) -> [URL] {
    let fm = FileManager.default
    var result: [URL] = []
    for url in urls {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
      if isDir.boolValue {
        let enumerator = fm.enumerator(
          at: url, includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles])
        while let file = enumerator?.nextObject() as? URL {
          if file.pathExtension.lowercased() == "md" {
            result.append(file)
          }
        }
      } else if url.pathExtension.lowercased() == "md" {
        result.append(url)
      }
    }
    return result
  }

  /// A file's page path is its path relative to the repo root, so importing
  /// `docs/design/auth.md` lands at that same path in the store. Files
  /// outside the repo tree fall back to their bare filename.
  nonisolated private static func relativePath(for file: URL, in repoRoot: URL) -> String {
    let rootPath = repoRoot.standardizedFileURL.path
    let filePath = file.standardizedFileURL.path
    if filePath.hasPrefix(rootPath + "/") {
      return String(filePath.dropFirst(rootPath.count + 1))
    }
    return file.lastPathComponent
  }

  /// Opens `path` chosen in the Go to Page palette and closes the palette.
  /// Like a sidebar click, this discards unsaved edits to the current page.
  func openFromPalette(_ path: String) {
    showPalette = false
    reveal(path)
    selection = path
  }

  func deleteSelection() async {
    guard let store, let path = selection else { return }
    do {
      try await run { try store.delete(path: path) }
      selection = nil
      await refresh()
    } catch {
      errorMessage = errorText(error)
    }
  }

  /// Selecting a folder row shows nothing: a folder is a path prefix shared by
  /// pages, not a stored object, so there is neither content nor an OID for it.
  private func loadSelection() async {
    guard let store, let path = selection, pages.contains(where: { $0.path == path }) else {
      text = ""
      info = nil
      isDirty = false
      return
    }
    do {
      let content = try await run { try store.read(path: path) }
      text = content
      isDirty = false
      info = try await run { try store.info(path: path) }
    } catch {
      errorMessage = errorText(error)
    }
  }

  /// Diffs the current page's content at `revision` against its current tip.
  func showDiff(against revision: Revision) async {
    guard let store, let path = selection else { return }
    do {
      let text = try await run {
        try store.diff(path: path, oldRev: revision.id, newRev: nil)
      }
      diff = PageDiff(path: path, revision: revision, text: text)
    } catch {
      errorMessage = errorText(error)
    }
  }

  /// Runs blocking git work off the main actor.
  private func run<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
  }
}
