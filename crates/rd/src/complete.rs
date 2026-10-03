//! Shell completion for `rd`, built on clap_complete's dynamic engine.
//!
//! A shell registers it with `source <(COMPLETE=zsh rd)` (or `bash`, `fish`).
//! Every TAB then re-runs `rd` with `COMPLETE` set, so doc paths come from the
//! repo in the current directory.

use std::collections::BTreeSet;
use std::ffi::OsStr;

use clap_complete::CompletionCandidate;
use rd_core::{DocStore, Git};

/// Completes a doc path one folder level at a time. Folders end in `/`.
pub fn doc_path(current: &OsStr) -> Vec<CompletionCandidate> {
    let Some(current) = current.to_str() else {
        return Vec::new();
    };
    let Ok(cwd) = std::env::current_dir() else {
        return Vec::new();
    };
    let Some(root) = Git::discover(&cwd) else {
        return Vec::new();
    };
    let Ok(pages) = DocStore::open(&root).list_pages() else {
        return Vec::new();
    };

    let mut candidates = BTreeSet::new();
    for page in pages {
        // The prefix match ignores ASCII case. The candidate keeps the doc's
        // own casing, so it replaces whatever the user typed.
        let Some(typed) = page.path.get(..current.len()) else {
            continue;
        };
        if !typed.eq_ignore_ascii_case(current) {
            continue;
        }
        // Extend the typed prefix to the end of the next segment.
        let end = match page.path[current.len()..].find('/') {
            Some(slash) => current.len() + slash + 1,
            None => page.path.len(),
        };
        candidates.insert(page.path[..end].to_string());
    }
    candidates
        .into_iter()
        .map(CompletionCandidate::new)
        .collect()
}
