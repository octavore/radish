import Foundation

/// One row in the sidebar: either a folder (with children) or a page (a leaf).
///
/// The page store has no folder objects — a "folder" is just a shared path
/// prefix among page paths, exactly as in a git tree. So the tree is derived
/// from the flat page list rather than stored, and an empty folder cannot
/// exist by construction.
struct DocNode: Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var page: Page?
  var children: [DocNode]?

  var isFolder: Bool { page == nil }
}

enum DocTree {
  /// Groups pages into a folder hierarchy by splitting their paths.
  ///
  /// `pendingFolders` are client-side-only placeholders (see
  /// `AppModel.createFolder`) — folder paths, each with a trailing `/`, that
  /// don't correspond to any page yet. They're folded in alongside the real
  /// ones so a just-created empty folder shows up in the sidebar before it
  /// has any content.
  static func build(_ pages: [Page], pendingFolders: Set<String> = []) -> [DocNode] {
    build(pages.sorted { $0.path < $1.path }, pendingFolders: pendingFolders, prefix: "")
  }

  private static func build(
    _ pages: [Page], pendingFolders: Set<String>, prefix: String
  ) -> [DocNode] {
    var folders: [String: [Page]] = [:]
    var folderOrder: [String] = []
    var leaves: [DocNode] = []

    for page in pages {
      let relative = String(page.path.dropFirst(prefix.count))
      let parts = relative.split(separator: "/", maxSplits: 1)

      if parts.count == 1 {
        leaves.append(DocNode(id: page.path, name: page.title, page: page, children: nil))
      } else {
        let folder = String(parts[0])
        if folders[folder] == nil {
          folders[folder] = []
          folderOrder.append(folder)
        }
        folders[folder]?.append(page)
      }
    }

    for pending in pendingFolders where pending.hasPrefix(prefix) {
      let relative = String(pending.dropFirst(prefix.count))
      guard !relative.isEmpty else { continue }
      let folder = String(relative.split(separator: "/", maxSplits: 1)[0])
      if folders[folder] == nil {
        folders[folder] = []
        folderOrder.append(folder)
      }
    }

    // Folders first, then loose pages — the usual file-browser convention.
    var nodes = folderOrder.sorted().map { folder -> DocNode in
      let nested = prefix + folder + "/"
      return DocNode(
        id: "folder:" + nested,
        name: folder,
        page: nil,
        children: build(folders[folder] ?? [], pendingFolders: pendingFolders, prefix: nested))
    }
    nodes.append(contentsOf: leaves)
    return nodes
  }
}

extension DocNode {
  /// The folder path a new item "created here" should be nested under: this
  /// node's own path if it's a folder, its parent's if it's a page, or the
  /// empty string at the root. Always empty or ending in `/`.
  var folderPrefix: String {
    if isFolder {
      return String(id.dropFirst("folder:".count))
    }
    guard let folder = page?.folder else { return "" }
    return folder + "/"
  }
}
