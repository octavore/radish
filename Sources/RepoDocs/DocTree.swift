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
  static func build(_ pages: [Page]) -> [DocNode] {
    build(pages.sorted { $0.path < $1.path }, prefix: "")
  }

  private static func build(_ pages: [Page], prefix: String) -> [DocNode] {
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

    // Folders first, then loose pages — the usual file-browser convention.
    var nodes = folderOrder.map { folder -> DocNode in
      let nested = prefix + folder + "/"
      return DocNode(
        id: "folder:" + nested,
        name: folder,
        page: nil,
        children: build(folders[folder] ?? [], prefix: nested))
    }
    nodes.append(contentsOf: leaves)
    return nodes
  }
}
