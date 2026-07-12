import Foundation

/// A free-standing markdown page, keyed by its path in the page tree.
struct Page: Identifiable, Hashable, Sendable {
  var path: String
  var id: String { path }

  /// `design/auth.md` -> `auth`
  var title: String {
    (path as NSString).lastPathComponent.replacingOccurrences(
      of: ".md", with: "", options: [.anchored, .backwards])
  }

  /// `design/auth.md` -> `design`, or nil at the top level.
  var folder: String? {
    let parent = (path as NSString).deletingLastPathComponent
    return parent.isEmpty ? nil : parent
  }
}

struct Revision: Identifiable, Sendable {
  var id: String  // commit oid
  var date: Date
  var subject: String
}

/// Where a page physically lives in the object database. Surfaced in the
/// inspector so the storage model is legible rather than magic — these are the
/// exact OIDs you can `git cat-file` from a terminal.
struct PageInfo: Sendable {
  var path: String
  var ref: String
  var blob: String
  var tip: String
  var byteCount: Int
  var revisions: [Revision]

  var lastModified: Date? { revisions.first?.date }
}

/// The outcome of merging a diverged doc ref.
enum MergeResult: Sendable {
  case upToDate
  case fastForwarded
  case merged
  /// Paths git could not auto-merge, with base/ours/theirs blobs for each.
  case conflicted([Conflict])
}

struct Conflict: Identifiable, Sendable {
  var id: String { path }
  var path: String
  var base: String?
  var ours: String?
  var theirs: String?
}

/// Git-backed storage for markdown, held outside the working tree.
///
/// Two stores, one engine (see SPEC-storage.md §2):
///   - Pages: free-standing docs in `refs/docs/pages`, keyed by human path.
///   - Annotations: true git notes in `refs/notes/annotations`, keyed by commit.
///
/// Pages deliberately do *not* use the notes porcelain. Keying a page by a
/// synthetic anchor object leaves that anchor unreachable, so `git gc` collects
/// it and `git notes prune` then deletes the page hanging off it — two routine
/// commands that silently destroy the store. A plain tree under `refs/docs/`
/// keeps every blob reachable and puts the store outside prune's blast radius.
struct DocStore: Sendable {
  static let pagesRef = "refs/docs/pages"
  static let notesRef = "refs/notes/annotations"
  static let pagesUpstream = "refs/docs/remotes/origin/pages"

  let git: Git

  init(root: URL) {
    self.git = Git(root: root)
  }

  // MARK: - Pages

  func listPages() throws -> [Page] {
    guard git.resolve(Self.pagesRef) != nil else { return [] }
    let listing = try git.text(["ls-tree", "-r", "--name-only", Self.pagesRef])
    guard !listing.isEmpty else { return [] }
    return
      listing
      .split(separator: "\n")
      .map { Page(path: String($0)) }
      .sorted { $0.path < $1.path }
  }

  func read(_ path: String) throws -> String {
    let data = try git.run(["cat-file", "-p", "\(Self.pagesRef):\(path)"])
    return String(decoding: data, as: UTF8.self)
  }

  /// Writes a page and advances the ref by compare-and-swap.
  ///
  /// `update-ref <ref> <new> <old>` aborts if the ref no longer equals `<old>`,
  /// so a concurrent writer loses the race instead of silently clobbering us.
  func write(path: String, content: String, message: String? = nil) throws {
    let old = git.resolve(Self.pagesRef)

    let tree = try git.withTemporaryIndex { env -> String in
      if let old {
        try git.run(["read-tree", old], env: env)
      }
      let blob = try git.text(["hash-object", "-w", "--stdin"], stdin: Data(content.utf8))
      try git.run(["update-index", "--add", "--cacheinfo", "100644,\(blob),\(path)"], env: env)
      return try git.text(["write-tree"], env: env)
    }

    try commitAndSwap(
      tree: tree, parents: [old].compactMap { $0 },
      message: message ?? "docs: update \(path)", expecting: old)
  }

  func delete(path: String) throws {
    guard let old = git.resolve(Self.pagesRef) else { return }

    let tree = try git.withTemporaryIndex { env -> String in
      try git.run(["read-tree", old], env: env)
      try git.run(["update-index", "--force-remove", path], env: env)
      return try git.text(["write-tree"], env: env)
    }

    try commitAndSwap(
      tree: tree, parents: [old], message: "docs: delete \(path)", expecting: old)
  }

  func info(for path: String) throws -> PageInfo {
    let blob = try git.text(["rev-parse", "\(Self.pagesRef):\(path)"])
    let size = Int(try git.text(["cat-file", "-s", blob])) ?? 0
    return PageInfo(
      path: path,
      ref: Self.pagesRef,
      blob: blob,
      tip: git.resolve(Self.pagesRef) ?? "",
      byteCount: size,
      revisions: try history(of: path))
  }

  func history(of path: String) throws -> [Revision] {
    guard git.resolve(Self.pagesRef) != nil else { return [] }
    let log = try git.text(
      ["log", "--format=%H%x00%at%x00%s", Self.pagesRef, "--", path])
    guard !log.isEmpty else { return [] }
    return log.split(separator: "\n").compactMap { line in
      let parts = line.components(separatedBy: "\0")
      guard parts.count == 3, let seconds = TimeInterval(parts[1]) else { return nil }
      return Revision(
        id: parts[0], date: Date(timeIntervalSince1970: seconds), subject: parts[2])
    }
  }

  // MARK: - Annotations
  //
  // Safe to use the notes porcelain here: the anchor is a real commit, which
  // stays reachable, so prune never touches it.

  func annotation(for commit: String) -> String? {
    let data = try? git.run(["notes", "--ref=annotations", "show", commit])
    guard let data else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  func setAnnotation(for commit: String, content: String) throws {
    try git.run(
      ["notes", "--ref=annotations", "add", "-f", "-F", "-", commit],
      stdin: Data(content.utf8))
  }

  // MARK: - Sync

  /// Configures the fetch refspecs. Notes and custom refs are not synced by
  /// default — the classic way a doc store silently diverges.
  func configureRemote(_ remote: String = "origin") throws {
    let specs = [
      "+\(Self.pagesRef):\(Self.pagesUpstream)",
      "+\(Self.notesRef):refs/notes/remotes/\(remote)/annotations",
    ]
    let existing = (try? git.text(["config", "--get-all", "remote.\(remote).fetch"])) ?? ""
    for spec in specs where !existing.contains(spec) {
      try git.run(["config", "--add", "remote.\(remote).fetch", spec])
    }
  }

  func fetch(_ remote: String = "origin") throws {
    try git.run(["fetch", remote])
  }

  /// Reconciles the local page ref with the last-fetched remote.
  ///
  /// `merge-tree --write-tree` does a full three-way merge in memory: no
  /// working tree, no index, no HEAD movement. On conflict it exits 1 and still
  /// prints the tree plus the conflicted stages, which is what lets us show a
  /// real base/ours/theirs view instead of a wall of `<<<<<<<` markers.
  func mergeFromUpstream() throws -> MergeResult {
    guard let theirs = git.resolve(Self.pagesUpstream) else { return .upToDate }
    guard let ours = git.resolve(Self.pagesRef) else {
      try git.run(["update-ref", Self.pagesRef, theirs, ""])
      return .fastForwarded
    }
    if ours == theirs { return .upToDate }

    if isAncestor(ours, of: theirs) {
      try git.run(["update-ref", Self.pagesRef, theirs, ours])
      return .fastForwarded
    }
    if isAncestor(theirs, of: ours) { return .upToDate }  // we're simply ahead

    let result = try git.capture(["merge-tree", "--write-tree", "--messages", ours, theirs])
    let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let tree = lines.first, !tree.isEmpty else {
      throw GitError.failed(args: ["merge-tree"], status: result.status, stderr: result.stderr)
    }

    if result.status != 0 {
      return .conflicted(Self.parseConflicts(lines.dropFirst()))
    }

    try commitAndSwap(
      tree: tree, parents: [ours, theirs], message: "docs: merge origin", expecting: ours)
    return .merged
  }

  func push(_ remote: String = "origin") throws {
    // --force-with-lease is the network-level analogue of the update-ref guard:
    // it refuses to overwrite a remote that moved since our last fetch. Never a
    // bare --force.
    try git.run([
      "push", "--force-with-lease=\(Self.pagesRef)", remote, "\(Self.pagesRef):\(Self.pagesRef)",
    ])
  }

  // MARK: - Internals

  private func isAncestor(_ a: String, of b: String) -> Bool {
    let result = try? git.capture(["merge-base", "--is-ancestor", a, b])
    return result?.status == 0
  }

  private func commitAndSwap(
    tree: String, parents: [String], message: String, expecting old: String?
  ) throws {
    var args = ["commit-tree", tree, "-m", message]
    for parent in parents { args += ["-p", parent] }
    let commit = try git.text(args)
    // An empty <old> asserts the ref must not already exist.
    try git.run(["update-ref", Self.pagesRef, commit, old ?? ""])
  }

  /// Parses `merge-tree`'s conflicted-file block: `<mode> <oid> <stage>\t<path>`,
  /// where stage 1/2/3 is base/ours/theirs.
  static func parseConflicts(_ lines: some Sequence<String>) -> [Conflict] {
    var byPath: [String: Conflict] = [:]
    for line in lines {
      if line.isEmpty { break }  // blank line ends the block; messages follow
      let halves = line.components(separatedBy: "\t")
      guard halves.count == 2 else { continue }
      let fields = halves[0].split(separator: " ").map(String.init)
      guard fields.count == 3, let stage = Int(fields[2]) else { continue }
      let path = halves[1]
      var conflict = byPath[path] ?? Conflict(path: path)
      switch stage {
      case 1: conflict.base = fields[1]
      case 2: conflict.ours = fields[1]
      case 3: conflict.theirs = fields[1]
      default: continue
      }
      byPath[path] = conflict
    }
    return byPath.values.sorted { $0.path < $1.path }
  }
}
