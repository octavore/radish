import Foundation
import XCTest

@testable import RepoDocs

final class DocStoreTests: XCTestCase {
  private var root: URL!
  private var store: DocStore!
  private var git: Git!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("repo-docs-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    git = Git(root: root)
    try git.run(["init", "--quiet", "."])
    try git.run(["config", "user.email", "test@example.com"])
    try git.run(["config", "user.name", "Test"])
    try git.run(["commit", "--quiet", "--allow-empty", "-m", "root"])

    store = DocStore(root: root)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testWriteThenReadRoundTripsVerbatim() throws {
    let source = "# Auth\n\nSome **bold** text and `code`.\n"
    try store.write(path: "design/auth.md", content: source)

    XCTAssertEqual(try store.read("design/auth.md"), source)
    XCTAssertEqual(try store.listPages().map(\.path), ["design/auth.md"])
  }

  func testFirstWriteCreatesRefAndSubsequentWritesBuildHistory() throws {
    XCTAssertTrue(try store.listPages().isEmpty)

    try store.write(path: "notes.md", content: "one\n")
    try store.write(path: "notes.md", content: "two\n")

    XCTAssertEqual(try store.read("notes.md"), "two\n")
    XCTAssertEqual(try store.history(of: "notes.md").count, 2)
  }

  /// The prime invariant: docs live entirely outside the checkout.
  func testWritingDocsLeavesWorkingTreeAndIndexUntouched() throws {
    try store.write(path: "design/auth.md", content: "# Auth\n")

    let status = try git.text(["status", "--porcelain"])
    XCTAssertEqual(status, "", "docs must not appear in the working tree or index")

    let tracked = try git.text(["ls-files"])
    XCTAssertEqual(tracked, "", "docs must not be staged")

    let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0 != ".git" }
    XCTAssertEqual(entries, [], "docs must not touch the filesystem")
  }

  func testDeleteRemovesPage() throws {
    try store.write(path: "a.md", content: "a\n")
    try store.write(path: "b.md", content: "b\n")

    try store.delete(path: "a.md")

    XCTAssertEqual(try store.listPages().map(\.path), ["b.md"])
  }

  func testAnnotationRoundTripsOnACommit() throws {
    let head = try git.text(["rev-parse", "HEAD"])

    XCTAssertNil(store.annotation(for: head))
    try store.setAnnotation(for: head, content: "why we did this\n")

    XCTAssertEqual(store.annotation(for: head), "why we did this\n")
  }

  /// A doc store keyed by synthetic anchors would lose data here. Ours must not:
  /// gc collects unreachable objects, and prune deletes notes whose anchor is
  /// gone. Pages live in a reachable tree outside refs/notes/, so they survive.
  func testPagesSurviveGarbageCollectionAndNotesPrune() throws {
    try store.write(path: "design/auth.md", content: "# Auth\n")

    try git.run(["gc", "--prune=now", "--quiet"])
    try git.run(["notes", "--ref=annotations", "prune"])

    XCTAssertEqual(try store.read("design/auth.md"), "# Auth\n")
  }

  func testConcurrentWriteLosesTheRaceInsteadOfClobbering() throws {
    try store.write(path: "a.md", content: "original\n")
    let stale = git.resolve(DocStore.pagesRef)

    // Someone else advances the ref behind our back.
    try store.write(path: "b.md", content: "other writer\n")

    // A write built on the stale tip must be rejected by the CAS guard.
    let tree = try git.withTemporaryIndex { env -> String in
      try git.run(["read-tree", stale!], env: env)
      let blob = try git.text(["hash-object", "-w", "--stdin"], stdin: Data("clobber\n".utf8))
      try git.run(["update-index", "--add", "--cacheinfo", "100644,\(blob),a.md"], env: env)
      return try git.text(["write-tree"], env: env)
    }
    let commit = try git.text(["commit-tree", tree, "-p", stale!, "-m", "stale"])
    XCTAssertThrowsError(try git.run(["update-ref", DocStore.pagesRef, commit, stale!]))

    // The other writer's page is still there.
    XCTAssertEqual(try store.read("b.md"), "other writer\n")
  }

  func testDivergedEditsMergeCleanly() throws {
    try store.write(path: "doc.md", content: "line one\nline two\nline three\n")
    let base = git.resolve(DocStore.pagesRef)!

    // Local edits the middle line.
    try store.write(path: "doc.md", content: "line one\nLOCAL\nline three\n")
    let ours = git.resolve(DocStore.pagesRef)!

    // A "remote" appends, branching from the same base.
    let theirs = try commit(
      onto: base, path: "doc.md", content: "line one\nline two\nline three\nREMOTE\n")
    try git.run(["update-ref", DocStore.pagesUpstream, theirs, ""])
    try git.run(["update-ref", DocStore.pagesRef, ours, ours])

    guard case .merged = try store.mergeFromUpstream() else {
      return XCTFail("expected a clean merge")
    }

    let merged = try store.read("doc.md")
    XCTAssertTrue(merged.contains("LOCAL"), "our edit survived")
    XCTAssertTrue(merged.contains("REMOTE"), "their edit survived")
  }

  func testOverlappingEditsReportConflictWithThreeStages() throws {
    try store.write(path: "doc.md", content: "line one\nline two\nline three\n")
    let base = git.resolve(DocStore.pagesRef)!

    try store.write(path: "doc.md", content: "line one\nOURS\nline three\n")

    let theirs = try commit(
      onto: base, path: "doc.md", content: "line one\nTHEIRS\nline three\n")
    try git.run(["update-ref", DocStore.pagesUpstream, theirs, ""])

    guard case .conflicted(let conflicts) = try store.mergeFromUpstream() else {
      return XCTFail("expected a conflict")
    }

    XCTAssertEqual(conflicts.map(\.path), ["doc.md"])
    let conflict = conflicts[0]
    XCTAssertNotNil(conflict.base)
    XCTAssertNotNil(conflict.ours)
    XCTAssertNotNil(conflict.theirs)

    // The stage blobs must be real, readable content — that is what lets the UI
    // show base/ours/theirs rather than conflict markers.
    let theirSide = try git.text(["cat-file", "-p", conflict.theirs!])
    XCTAssertTrue(theirSide.contains("THEIRS"))
  }

  // MARK: - Helpers

  /// Builds a commit on top of `parent` with `path` set to `content`.
  private func commit(onto parent: String, path: String, content: String) throws -> String {
    let tree = try git.withTemporaryIndex { env -> String in
      try git.run(["read-tree", parent], env: env)
      let blob = try git.text(["hash-object", "-w", "--stdin"], stdin: Data(content.utf8))
      try git.run(["update-index", "--add", "--cacheinfo", "100644,\(blob),\(path)"], env: env)
      return try git.text(["write-tree"], env: env)
    }
    return try git.text(["commit-tree", tree, "-p", parent, "-m", "remote edit"])
  }
}
