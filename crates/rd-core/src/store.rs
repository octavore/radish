use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::error::{Result, StoreError};
use crate::git::Git;
use crate::types::{Conflict, MergeResult, Page, PageInfo, Revision};

pub const PAGES_REF: &str = "refs/docs/pages";
pub const NOTES_REF: &str = "refs/notes/annotations";
pub const DEFAULT_REMOTE: &str = "origin";

/// Doc paths that may hold a rumdl config, in rumdl's own filename precedence.
const RUMDL_CONFIG_DOCS: [&str; 2] = [".rumdl.toml", "rumdl.toml"];

/// Where `remote`'s page ref is mirrored locally after a fetch.
///
/// Scoped by remote name, exactly as the notes mirror is: two remotes fetching
/// into one ref would leave `merge_from_upstream` merging from whichever
/// happened to fetch last.
pub fn pages_upstream(remote: &str) -> String {
    format!("refs/docs/remotes/{remote}/pages")
}

fn remote_or_default(remote: Option<String>) -> String {
    remote.unwrap_or_else(|| DEFAULT_REMOTE.to_string())
}

/// Git-backed storage for markdown, held outside the working tree.
///
/// Two stores over one engine (see `docs/STORAGE.md` §2, via `rd`):
///   - Pages: free-standing docs in `refs/docs/pages`, keyed by human path.
///   - Annotations: true git notes in `refs/notes/annotations`, keyed by
///     commit.
///
/// Pages deliberately do *not* use the notes porcelain. Keying a page by a
/// synthetic anchor object leaves that anchor unreachable, so `git gc` collects
/// it and `git notes prune` then deletes the page hanging off it. Both are
/// routine commands that would silently destroy the store. A plain tree under
/// `refs/docs/`
/// keeps every blob reachable, so neither command can reach the store.
#[derive(Debug, uniffi::Object)]
pub struct DocStore {
    git: Git,
}

impl DocStore {
    pub fn open(root: impl Into<PathBuf>) -> Self {
        Self {
            git: Git::new(root),
        }
    }

    pub fn root(&self) -> &Path {
        &self.git.root
    }

    /// Reads a page and its blob OID, both from one resolution of the ref tip,
    /// so the OID describes exactly the content returned. Pass the OID back to
    /// `write_expecting` to reject the write if the page changed in between.
    pub fn read_with_blob(&self, path: &str) -> Result<(String, String)> {
        let tip = self
            .git
            .resolve(PAGES_REF)
            .unwrap_or_else(|| PAGES_REF.to_string());
        let blob = self.git.text(&["rev-parse", &format!("{tip}:{path}")])?;
        let bytes = self.git.run(&["cat-file", "-p", &blob])?;
        let content =
            String::from_utf8(bytes).map_err(|_| StoreError::NotUtf8(path.to_string()))?;
        Ok((content, blob))
    }

    /// `write`, but when `expected_blob` is given the write fails with
    /// `StoreError::Stale` unless the page's current blob OID equals it. The
    /// check reads the same ref tip the compare-and-swap later guards, so a
    /// change landing between the check and the swap is rejected too. Changes
    /// to other pages do not count.
    ///
    /// Returns `false`, having committed nothing, when the content is already
    /// what the page holds.
    pub fn write_expecting(
        &self,
        path: &str,
        content: &str,
        message: Option<String>,
        expected_blob: Option<&str>,
    ) -> Result<bool> {
        let old = self.git.resolve(PAGES_REF);

        if let Some(expected) = expected_blob {
            let actual = old.as_deref().and_then(|old| self.blob_at(old, path));
            if actual.as_deref() != Some(expected) {
                return Err(StoreError::Stale {
                    path: path.to_string(),
                    expected: expected.to_string(),
                    actual: actual.unwrap_or_else(|| "none".to_string()),
                });
            }
        }

        let tree = self.git.with_temporary_index(|env| {
            if let Some(old) = &old {
                self.git.run_with(&["read-tree", old], None, env)?;
            }
            let blob = self.git.text_with(
                &["hash-object", "-w", "--stdin"],
                Some(content.as_bytes()),
                env,
            )?;
            self.git.run_with(
                &[
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    &format!("100644,{blob},{path}"),
                ],
                None,
                env,
            )?;
            self.git.text_with(&["write-tree"], None, env)
        })?;

        let message = message.unwrap_or_else(|| format!("docs: update {path}"));
        self.swap_page_tree(&tree, old.as_deref(), &message)
    }

    /// Replaces `old` with `new` in a page and writes it back. Unless `all` is
    /// set, `old` must occur exactly once. The write is guarded by the blob
    /// the replacement was computed from, so a concurrent edit to the page
    /// fails with `StoreError::Stale` instead of being overwritten. Returns
    /// how many occurrences were replaced.
    pub fn replace(&self, path: &str, old: &str, new: &str, all: bool) -> Result<usize> {
        if old.is_empty() {
            return Err(StoreError::Replace {
                path: path.to_string(),
                reason: "the text to replace is empty".to_string(),
            });
        }
        let (content, blob) = self.read_with_blob(path)?;
        let count = content.matches(old).count();
        let reason = match count {
            0 => Some("the text to replace was not found".to_string()),
            1 => None,
            n if !all => Some(format!(
                "the text to replace occurs {n} times; add more context or replace all"
            )),
            _ => None,
        };
        if let Some(reason) = reason {
            return Err(StoreError::Replace {
                path: path.to_string(),
                reason,
            });
        }

        let updated = content.replace(old, new);
        self.write_expecting(path, &updated, None, Some(&blob))?;
        Ok(count)
    }

    /// Moves a page, or every page under a folder, to a new path in one
    /// commit. Fails with `StoreError::NotFound` when `from` is neither a page
    /// nor a folder, and with `StoreError::Exists` when any destination is
    /// already a page. Returns the `(from, to)` path of each moved page.
    pub fn rename(&self, from: &str, to: &str) -> Result<Vec<(String, String)>> {
        let from = from.trim_end_matches('/');
        let to = to.trim_end_matches('/');
        let old = self
            .git
            .resolve(PAGES_REF)
            .ok_or_else(|| StoreError::NotFound(from.to_string()))?;
        let pages: Vec<String> = self
            .list_pages()?
            .into_iter()
            .map(|page| page.path)
            .collect();

        let moves: Vec<(String, String)> = if pages.iter().any(|page| page == from) {
            vec![(from.to_string(), to.to_string())]
        } else {
            let prefix = format!("{from}/");
            pages
                .iter()
                .filter_map(|page| {
                    let rest = page.strip_prefix(&prefix)?;
                    Some((page.clone(), format!("{to}/{rest}")))
                })
                .collect()
        };
        if moves.is_empty() {
            return Err(StoreError::NotFound(from.to_string()));
        }
        if let Some((_, taken)) = moves.iter().find(|(_, dest)| pages.contains(dest)) {
            return Err(StoreError::Exists(taken.clone()));
        }

        let tree = self.git.with_temporary_index(|env| {
            self.git.run_with(&["read-tree", &old], None, env)?;
            for (source, dest) in &moves {
                let blob = self
                    .blob_at(&old, source)
                    .ok_or_else(|| StoreError::NotFound(source.clone()))?;
                self.git
                    .run_with(&["update-index", "--force-remove", source], None, env)?;
                self.git.run_with(
                    &[
                        "update-index",
                        "--add",
                        "--cacheinfo",
                        &format!("100644,{blob},{dest}"),
                    ],
                    None,
                    env,
                )?;
            }
            self.git.text_with(&["write-tree"], None, env)
        })?;

        let message = format!("docs: move {from} to {to}");
        self.swap_page_tree(&tree, Some(&old), &message)?;
        Ok(moves)
    }

    /// The blob OID at `path` in the tree of `commit`, or `None` when there is
    /// no such path.
    fn blob_at(&self, commit: &str, path: &str) -> Option<String> {
        self.git.resolve(&format!("{commit}:{path}"))
    }

    /// Commits `tree` as a single-parent page edit on top of `old` and swaps
    /// it in. Returns `false`, having committed nothing, when `tree` equals
    /// `old`'s tree, so an unchanged write leaves no empty commit in history.
    /// Merges go through `commit_and_swap` directly, since a merge must record
    /// its second parent even when the tree is unchanged.
    fn swap_page_tree(&self, tree: &str, old: Option<&str>, message: &str) -> Result<bool> {
        if let Some(old) = old {
            if self.git.resolve(&format!("{old}^{{tree}}")).as_deref() == Some(tree) {
                return Ok(false);
            }
        }
        let parents: Vec<String> = old.map(str::to_string).into_iter().collect();
        let message = self.stamp_repo_commit(message);
        self.commit_and_swap(tree, &parents, &message, old)?;
        Ok(true)
    }
}

#[uniffi::export]
impl DocStore {
    /// Errors when `root` isn't a git repository, so a bad path fails here
    /// rather than on the first read.
    #[uniffi::constructor]
    pub fn new(root: String) -> Result<Self> {
        let root = PathBuf::from(root);
        if !Git::is_repository(&root) {
            return Err(StoreError::not_a_repository(&root));
        }
        Ok(Self::open(root))
    }

    // MARK: - Pages

    pub fn list_pages(&self) -> Result<Vec<Page>> {
        if self.git.resolve(PAGES_REF).is_none() {
            return Ok(Vec::new());
        }
        // `-z`: NUL-separated and never quoted, so a path containing a quote,
        // a backslash, or a newline survives verbatim.
        let listing = self
            .git
            .run(&["ls-tree", "-r", "--name-only", "-z", PAGES_REF])?;
        let mut pages: Vec<Page> = String::from_utf8_lossy(&listing)
            .split('\0')
            .filter(|entry| !entry.is_empty())
            .map(Page::new)
            .collect();
        pages.sort_by(|a, b| a.path.cmp(&b.path));
        Ok(pages)
    }

    pub fn read(&self, path: String) -> Result<String> {
        let bytes = self
            .git
            .run(&["cat-file", "-p", &format!("{PAGES_REF}:{path}")])?;
        String::from_utf8(bytes).map_err(|_| StoreError::NotUtf8(path))
    }

    /// Reformats `content` with rumdl and returns the result, without writing
    /// anything. The config is resolved the way rumdl resolves it, with one
    /// added tier: a `rumdl.toml` (or `.rumdl.toml`) stored as a doc wins over
    /// a config in the repo working tree, which wins over the user-level
    /// config. rumdl picks a single source rather than merging them. When
    /// rumdl reports an internal error the text comes back unchanged.
    pub fn reformat(&self, content: String) -> Result<String> {
        let pages = self.list_pages()?;
        let config_doc = RUMDL_CONFIG_DOCS
            .iter()
            .find(|name| pages.iter().any(|page| page.path == **name))
            .map(|name| self.read(name.to_string()))
            .transpose()?;
        Ok(crate::fmt::reformat(
            &content,
            config_doc.as_deref(),
            self.root(),
        ))
    }

    /// Writes a page and advances the ref by compare-and-swap.
    ///
    /// `update-ref <ref> <new> <old>` aborts if the ref no longer equals
    /// `<old>`, so a concurrent writer loses the race instead of silently
    /// clobbering us.
    pub fn write(&self, path: String, content: String, message: Option<String>) -> Result<()> {
        self.write_expecting(&path, &content, message, None)?;
        Ok(())
    }

    pub fn delete(&self, path: String) -> Result<()> {
        let Some(old) = self.git.resolve(PAGES_REF) else {
            return Ok(());
        };

        let tree = self.git.with_temporary_index(|env| {
            self.git.run_with(&["read-tree", &old], None, env)?;
            self.git
                .run_with(&["update-index", "--force-remove", &path], None, env)?;
            self.git.text_with(&["write-tree"], None, env)
        })?;

        self.swap_page_tree(&tree, Some(&old), &format!("docs: delete {path}"))?;
        Ok(())
    }

    pub fn info(&self, path: String) -> Result<PageInfo> {
        let blob = self
            .git
            .text(&["rev-parse", &format!("{PAGES_REF}:{path}")])?;
        let byte_count = self
            .git
            .text(&["cat-file", "-s", &blob])?
            .parse()
            .unwrap_or(0);
        Ok(PageInfo {
            revisions: self.history(path.clone())?,
            path,
            reference: PAGES_REF.to_string(),
            blob,
            tip: self.git.resolve(PAGES_REF).unwrap_or_default(),
            byte_count,
        })
    }

    /// Unified diff of a page between one historical revision and another (the
    /// current tip by default). Revisions come from `history`, so `old_rev` is
    /// always a commit on `PAGES_REF`'s own chain, not the repo's.
    pub fn diff(&self, path: String, old_rev: String, new_rev: Option<String>) -> Result<String> {
        let new_rev = new_rev.unwrap_or_else(|| PAGES_REF.to_string());
        self.git
            .text(&["diff", "--no-color", &old_rev, &new_rev, "--", &path])
    }

    pub fn history(&self, path: String) -> Result<Vec<Revision>> {
        if self.git.resolve(PAGES_REF).is_none() {
            return Ok(Vec::new());
        }
        let log = self
            .git
            .text(&["log", "--format=%H%x00%at%x00%s", PAGES_REF, "--", &path])?;
        Ok(log
            .lines()
            .filter(|line| !line.is_empty())
            .filter_map(|line| {
                let mut parts = line.split('\0');
                let id = parts.next()?.to_string();
                let seconds: u64 = parts.next()?.parse().ok()?;
                let subject = parts.next()?.to_string();
                Some(Revision {
                    id,
                    date: UNIX_EPOCH + Duration::from_secs(seconds),
                    subject,
                })
            })
            .collect())
    }

    /// Last-modified time for every page, in one `git log` pass rather than one
    /// per path. `history` walks the whole `PAGES_REF` history per call, which
    /// is fine for a single page but O(pages × commits) across all of them. Log
    /// is newest-first, so the first commit touching a path is its most recent
    /// modification.
    pub fn last_modified_times(&self) -> Result<HashMap<String, SystemTime>> {
        if self.git.resolve(PAGES_REF).is_none() {
            return Ok(HashMap::new());
        }
        let log = self
            .git
            .text(&["log", "--format=\u{1}%at", "--name-only", PAGES_REF])?;

        let mut result = HashMap::new();
        let mut current: Option<SystemTime> = None;
        for line in log.lines() {
            if let Some(stamp) = line.strip_prefix('\u{1}') {
                current = stamp
                    .parse::<u64>()
                    .ok()
                    .map(|seconds| UNIX_EPOCH + Duration::from_secs(seconds));
            } else if !line.is_empty() {
                if let Some(date) = current {
                    result.entry(line.to_string()).or_insert(date);
                }
            }
        }
        Ok(result)
    }

    // MARK: - Annotations
    //
    // Safe to use the notes porcelain here: the anchor is a real commit, which
    // stays reachable, so prune never touches it.

    pub fn annotation(&self, commit: String) -> Option<String> {
        self.git
            .text(&["notes", "--ref=annotations", "show", &commit])
            .ok()
    }

    pub fn set_annotation(&self, commit: String, content: String) -> Result<()> {
        self.git.run_with(
            &[
                "notes",
                "--ref=annotations",
                "add",
                "-f",
                "-F",
                "-",
                &commit,
            ],
            Some(content.as_bytes()),
            &HashMap::new(),
        )?;
        Ok(())
    }

    // MARK: - Sync

    /// Configures the fetch refspecs. Git does not sync notes or custom refs by
    /// default, so without this the doc store diverges silently.
    pub fn configure_remote(&self, remote: Option<String>) -> Result<()> {
        let remote = remote_or_default(remote);
        let specs = [
            format!("+{PAGES_REF}:{}", pages_upstream(&remote)),
            format!("+{NOTES_REF}:refs/notes/remotes/{remote}/annotations"),
        ];
        let key = format!("remote.{remote}.fetch");
        let existing = self
            .git
            .text(&["config", "--get-all", &key])
            .unwrap_or_default();
        // One whole line per configured refspec: a substring test would treat
        // an unrelated `…/pages-old` spec as this one already being present.
        let existing: Vec<&str> = existing.lines().map(str::trim).collect();
        for spec in &specs {
            if !existing.contains(&spec.as_str()) {
                self.git.run(&["config", "--add", &key, spec])?;
            }
        }
        Ok(())
    }

    pub fn fetch(&self, remote: Option<String>) -> Result<()> {
        let remote = remote_or_default(remote);
        self.git.run(&["fetch", &remote])?;
        Ok(())
    }

    /// Reconciles the local page ref with the last-fetched remote.
    ///
    /// `merge-tree --write-tree` does a full three-way merge in memory: no
    /// working tree, no index, no HEAD movement. On conflict it exits 1 and
    /// still prints the tree plus the conflicted stages, which is what lets us
    /// show a real base/ours/theirs view instead of `<<<<<<<` conflict markers.
    pub fn merge_from_upstream(&self, remote: Option<String>) -> Result<MergeResult> {
        let upstream = pages_upstream(&remote_or_default(remote));
        let Some(theirs) = self.git.resolve(&upstream) else {
            return Ok(MergeResult::UpToDate);
        };
        let Some(ours) = self.git.resolve(PAGES_REF) else {
            self.git.run(&["update-ref", PAGES_REF, &theirs, ""])?;
            return Ok(MergeResult::FastForwarded);
        };
        if ours == theirs {
            return Ok(MergeResult::UpToDate);
        }

        if self.is_ancestor(&ours, &theirs) {
            self.git.run(&["update-ref", PAGES_REF, &theirs, &ours])?;
            return Ok(MergeResult::FastForwarded);
        }
        if self.is_ancestor(&theirs, &ours) {
            return Ok(MergeResult::UpToDate); // we're simply ahead
        }

        let args = ["merge-tree", "--write-tree", "--messages", &ours, &theirs];
        let result = self.git.capture(&args, None, &HashMap::new())?;
        let stdout = String::from_utf8_lossy(&result.stdout);
        let mut lines = stdout.lines();
        let tree = lines.next().unwrap_or_default().trim().to_string();
        if tree.is_empty() {
            let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
            return Err(StoreError::git(&args, result.status, &result.stderr));
        }

        if result.status != 0 {
            return Ok(MergeResult::Conflicted {
                conflicts: parse_conflicts(lines),
            });
        }

        let parents = [ours.clone(), theirs];
        self.commit_and_swap(&tree, &parents, "docs: merge origin", Some(&ours))?;
        Ok(MergeResult::Merged)
    }

    pub fn push(&self, remote: Option<String>) -> Result<()> {
        let remote = remote_or_default(remote);
        // --force-with-lease is the network-level analogue of the update-ref
        // guard: it refuses to overwrite a remote that moved since our last
        // fetch. Never a bare --force.
        //
        // The expected value is spelled out rather than left implicit: without
        // it git derives the lease from the remote-tracking ref it finds via
        // the configured fetch refspec, which only exists once
        // `configure_remote` has run. Naming our last-fetched mirror directly
        // makes the guard work regardless.
        let lease = match self.git.resolve(&pages_upstream(&remote)) {
            Some(mirror) => format!("--force-with-lease={PAGES_REF}:{mirror}"),
            // Nothing fetched yet, so the lease is "the ref must not exist":
            // a remote that already has pages rejects the push, which is the
            // safe direction: fetch first.
            None => format!("--force-with-lease={PAGES_REF}:"),
        };
        self.git
            .run(&["push", &lease, &remote, &format!("{PAGES_REF}:{PAGES_REF}")])?;
        Ok(())
    }
}

impl DocStore {
    // MARK: - Internals

    fn is_ancestor(&self, a: &str, b: &str) -> bool {
        self.git
            .capture(
                &["merge-base", "--is-ancestor", a, b],
                None,
                &HashMap::new(),
            )
            .map(|result| result.status == 0)
            .unwrap_or(false)
    }

    fn commit_and_swap(
        &self,
        tree: &str,
        parents: &[String],
        message: &str,
        old: Option<&str>,
    ) -> Result<()> {
        let mut args = vec!["commit-tree", tree, "-m", message];
        for parent in parents {
            args.push("-p");
            args.push(parent);
        }
        let commit = self.git.text(&args)?;
        // An empty <old> asserts the ref must not already exist.
        self.git
            .run(&["update-ref", PAGES_REF, &commit, old.unwrap_or("")])?;
        Ok(())
    }

    /// Appends the `Repo-Commit` trailer from `docs/STORAGE.md` §4: which repo
    /// commit was checked out when the page was written. A trailer rather than
    /// a raw commit header, so stock tooling (`git log`,
    /// `git interpret-trailers`) can read it back.
    ///
    /// Known gap, also per §4: this records `HEAD`, not working-tree state, so
    /// read it as "written no earlier than this commit."
    fn stamp_repo_commit(&self, message: &str) -> String {
        // Empty on an unborn branch, where there is no HEAD to record.
        match self.git.resolve("HEAD") {
            Some(head) => format!("{message}\n\nRepo-Commit: {head}"),
            None => message.to_string(),
        }
    }
}

/// Parses `merge-tree`'s conflicted-file block: `<mode> <oid> <stage>\t<path>`,
/// where stage 1/2/3 is base/ours/theirs.
pub(crate) fn parse_conflicts<'a>(lines: impl Iterator<Item = &'a str>) -> Vec<Conflict> {
    let mut by_path: HashMap<String, Conflict> = HashMap::new();
    for line in lines {
        if line.is_empty() {
            break; // blank line ends the block; messages follow
        }
        let Some((meta, path)) = line.split_once('\t') else {
            continue;
        };
        let fields: Vec<&str> = meta.split(' ').collect();
        let [_mode, oid, stage] = fields[..] else {
            continue;
        };
        let entry = by_path.entry(path.to_string()).or_insert_with(|| Conflict {
            path: path.to_string(),
            ..Default::default()
        });
        match stage {
            "1" => entry.base = Some(oid.to_string()),
            "2" => entry.ours = Some(oid.to_string()),
            "3" => entry.theirs = Some(oid.to_string()),
            _ => continue,
        }
    }
    let mut conflicts: Vec<Conflict> = by_path.into_values().collect();
    conflicts.sort_by(|a, b| a.path.cmp(&b.path));
    conflicts
}
