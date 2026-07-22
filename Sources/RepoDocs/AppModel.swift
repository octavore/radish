import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
  private(set) var repo: URL?
  private(set) var pages: [Page] = []
  private(set) var tree: [DocNode] = []
  /// Folders created via the sidebar's "New Folder" but not yet holding a
  /// page — see `createFolder`. Client-side only; lost on refresh/reopen.
  private(set) var pendingFolders: Set<String> = []
  private(set) var status: String = ""
  /// Git identity of the selected page, shown in the inspector. Nil for a
  /// folder row, which is a path prefix rather than a stored object.
  private(set) var info: PageInfo?
  var showInspector = true
  var errorMessage: String?

  /// Set when the user asks to diff the current page against a past revision;
  /// presenting it drives a sheet in ContentView.
  var diff: PageDiff?

  /// The editor's document: raw markdown source, verbatim. The editor
  /// highlights this string itself, so it must round-trip exactly — a
  /// load→save cycle must never rewrite it, or git history fills with
  /// phantom diffs.
  var text = ""
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
    pendingFolders = []
    info = nil
    text = ""
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
      tree = DocTree.build(found, pendingFolders: pendingFolders)
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
    let content = text
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

  /// Adds a folder to the sidebar without writing anything to git — the
  /// store has no folder objects (see `DocTree`), so an empty folder can't
  /// actually be persisted. This just seeds `pendingFolders`, which
  /// `DocTree.build` folds into the tree; the folder becomes "real" the
  /// moment a page is created inside it, and simply vanishes (never having
  /// existed as far as git is concerned) if the repo is refreshed or
  /// reopened before that happens.
  func createFolder(path rawPath: String) {
    let trimmed = rawPath
      .trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty else { return }
    pendingFolders.insert(trimmed + "/")
    tree = DocTree.build(pages, pendingFolders: pendingFolders)
  }

  /// Imports existing markdown files already sitting in the repo's working
  /// tree (or elsewhere on disk) into the page store. Directories are walked
  /// recursively for `.md` files; a file's page path is its path relative to
  /// the repo root, so an import round-trips back to the same tree shape.
  /// Reading is plain `FileManager`/`String(contentsOf:)` off the working
  /// tree — the store write goes through the usual §1 plumbing, so this never
  /// touches the index or `HEAD`.
  func importPaths(_ urls: [URL]) async {
    guard let store, let repoRoot = repo else { return }
    do {
      let count = try await run { () -> Int in
        let files = Self.collectMarkdownFiles(urls)
        for file in files {
          let relative = Self.relativePath(for: file, in: repoRoot)
          let content = try String(contentsOf: file, encoding: .utf8)
          try store.write(path: relative, content: content, message: "docs: import \(relative)")
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
      errorMessage = error.localizedDescription
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
      text = ""
      info = nil
      isDirty = false
      return
    }
    do {
      let content = try await run { try store.read(path) }
      text = content
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
