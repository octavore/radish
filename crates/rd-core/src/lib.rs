//! Git-backed storage for markdown held outside a repository's working tree.
//!
//! One implementation, two consumers: the `rd` CLI links this as an ordinary
//! Rust crate, and the Radish SwiftUI app links the staticlib through the
//! UniFFI bindings generated from these `#[uniffi::export]` items. Everything
//! the spec in `docs/STORAGE.md` describes lives here, so the app and the CLI
//! stay in sync.

pub mod error;
pub mod fmt;
pub mod fuzzy;
pub mod git;
pub mod store;
pub mod tree;
pub mod types;

pub use error::{Result, StoreError};
pub use fuzzy::fuzzy_match;
pub use git::Git;
pub use store::{pages_upstream, DocStore, DEFAULT_REMOTE, NOTES_REF, PAGES_REF};
pub use tree::{build_tree, DocNode};
pub use types::{Conflict, FuzzyMatch, MergeResult, Page, PageDiff, PageEntry, PageInfo, Revision};

uniffi::setup_scaffolding!();

/// Whether `path` is inside a git repository. Mirrors `Git.isRepository`, which
/// `AppModel` calls before opening a repo.
#[uniffi::export]
pub fn is_repository(path: String) -> bool {
    Git::is_repository(std::path::Path::new(&path))
}

/// The repository root containing `path`, or `None` when it isn't in one.
#[uniffi::export]
pub fn discover_repository(path: String) -> Option<String> {
    Git::discover(std::path::Path::new(&path)).map(|root| root.display().to_string())
}

/// `design/auth.md` -> `auth`. Exported so Swift's `Page.title` and the CLI
/// share one definition.
#[uniffi::export]
pub fn page_title(path: String) -> String {
    Page::new(path).title()
}

/// `design/auth.md` -> `design`, or `None` at the top level.
#[uniffi::export]
pub fn page_folder(path: String) -> Option<String> {
    Page::new(path).folder()
}
