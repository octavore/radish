import Foundation
import RepoDocsCore

// Conveniences over the UniFFI-generated types in `RepoDocsCore`: identity for
// SwiftUI, and error text for alerts. The storage behaviour itself lives in
// Rust, in `crates/rd-core`.

extension Page: Identifiable {
  public var id: String { path }

  /// `design/auth.md` -> `auth`
  var title: String { pageTitle(path: path) }

  /// `design/auth.md` -> `design`, or nil at the top level.
  var folder: String? { pageFolder(path: path) }
}

extension Revision: Identifiable {}

extension DocNode: Identifiable {
  var isFolder: Bool { page == nil }

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

extension PageInfo {
  var lastModified: Date? { revisions.first?.date }
}

/// A unified diff of one page between a past revision and the current tip.
///
/// Swift-side only: the app builds this to drive its diff sheet, and nothing in
/// the storage layer needs to see it.
struct PageDiff: Identifiable, Sendable {
  var id: String { revision.id }
  var path: String
  var revision: Revision
  /// Raw `git diff` output. Empty when the revision already matches the tip.
  var text: String
}

/// Text for an error alert.
///
/// UniFFI does conform `StoreError` to `LocalizedError`, but its generated
/// `errorDescription` is `String(reflecting: self)`: the Swift case name
/// wrapped around the real text (`StoreError.Git(message: "git … failed")`).
/// Since that conformance lives in the declaring module, an extension here
/// can't replace it, so unwrap the case explicitly instead.
func errorText(_ error: Error) -> String {
  guard let error = error as? StoreError else { return error.localizedDescription }
  switch error {
  case let .Git(message), let .Spawn(message), let .NotARepository(message),
    let .Io(message), let .NotUtf8(message):
    return message
  }
}
