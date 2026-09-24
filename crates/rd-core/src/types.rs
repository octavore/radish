use std::time::SystemTime;

/// A free-standing markdown page, keyed by its path in the page tree.
///
/// The Swift side adds `title`/`folder` as computed properties in
/// `CoreExtensions.swift`; they're derived from `path` and don't belong in the
/// FFI record.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct Page {
    pub path: String,
}

/// A page as `ls-tree -l` sees it. Rust-only; not part of the FFI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageEntry {
    pub path: String,
    pub blob: String,
    pub size: u64,
}

impl Page {
    pub fn new(path: impl Into<String>) -> Self {
        Self { path: path.into() }
    }

    /// `design/auth.md` -> `auth`
    pub fn title(&self) -> String {
        let name = self.path.rsplit('/').next().unwrap_or(&self.path);
        name.strip_suffix(".md").unwrap_or(name).to_string()
    }

    /// `design/auth.md` -> `design`, or `None` at the top level.
    pub fn folder(&self) -> Option<String> {
        self.path
            .rsplit_once('/')
            .map(|(parent, _)| parent.to_string())
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Revision {
    /// commit oid
    pub id: String,
    pub date: SystemTime,
    pub subject: String,
}

/// Where a page physically lives in the object database. Surfaced in the
/// inspector so the storage model is legible: these are the exact OIDs you can
/// `git cat-file` from a terminal.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PageInfo {
    pub path: String,
    pub reference: String,
    pub blob: String,
    pub tip: String,
    pub byte_count: u64,
    pub revisions: Vec<Revision>,
}

impl PageInfo {
    pub fn last_modified(&self) -> Option<SystemTime> {
        self.revisions.first().map(|revision| revision.date)
    }
}

/// A unified diff of one page between a past revision and the current tip.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PageDiff {
    pub path: String,
    pub revision: Revision,
    /// Raw `git diff` output. Empty when the revision already matches the tip.
    pub text: String,
}

/// One result from `fuzzy_match`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FuzzyMatch {
    pub path: String,
    /// Higher is better. Only meaningful relative to other results for the
    /// same query.
    pub score: u32,
    /// Offsets of the matched characters in `path`, counted in Unicode scalar
    /// values (not bytes or grapheme clusters), ascending.
    pub indices: Vec<u32>,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct Conflict {
    pub path: String,
    pub base: Option<String>,
    pub ours: Option<String>,
    pub theirs: Option<String>,
}

/// The outcome of merging a diverged doc ref.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum MergeResult {
    UpToDate,
    FastForwarded,
    Merged,
    /// Paths git could not auto-merge, with base/ours/theirs blobs for each.
    Conflicted {
        conflicts: Vec<Conflict>,
    },
}
