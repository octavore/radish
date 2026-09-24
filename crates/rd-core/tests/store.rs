//! Ported from `Tests/RepoDocsTests/DocStoreTests.swift`.

use rd_core::store::{pages_upstream, PAGES_REF};
use rd_core::{DocStore, Git, MergeResult, StoreError};
use tempfile::TempDir;

/// A throwaway repository with one empty root commit, plus the store under
/// test and a raw `Git` for poking at it from outside the store's API.
struct Fixture {
    _dir: TempDir,
    git: Git,
    store: DocStore,
}

fn fixture() -> Fixture {
    let dir = tempfile::Builder::new()
        .prefix("repo-docs-test-")
        .tempdir()
        .unwrap();
    let root = dir.path().to_path_buf();

    let git = Git::new(&root);
    git.run(&["init", "--quiet", "."]).unwrap();
    git.run(&["config", "user.email", "test@example.com"])
        .unwrap();
    git.run(&["config", "user.name", "Test"]).unwrap();
    // Pin git's own default rather than inheriting the developer's ~/.gitconfig:
    // someone with `core.quotePath = false` set globally would otherwise never
    // see the path-quoting these tests exist to catch.
    git.run(&["config", "core.quotePath", "true"]).unwrap();
    git.run(&["commit", "--quiet", "--allow-empty", "-m", "root"])
        .unwrap();

    let store = DocStore::open(&root);
    Fixture {
        _dir: dir,
        git,
        store,
    }
}

/// Builds a commit on top of `parent` with `path` set to `content`.
fn commit_onto(git: &Git, parent: &str, path: &str, content: &str) -> String {
    let tree = git
        .with_temporary_index(|env| {
            git.run_with(&["read-tree", parent], None, env)?;
            let blob = git.text_with(
                &["hash-object", "-w", "--stdin"],
                Some(content.as_bytes()),
                env,
            )?;
            git.run_with(
                &[
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    &format!("100644,{blob},{path}"),
                ],
                None,
                env,
            )?;
            git.text_with(&["write-tree"], None, env)
        })
        .unwrap();
    git.text(&["commit-tree", &tree, "-p", parent, "-m", "remote edit"])
        .unwrap()
}

fn paths(store: &DocStore) -> Vec<String> {
    store
        .list_pages()
        .unwrap()
        .into_iter()
        .map(|page| page.path)
        .collect()
}

#[test]
fn write_then_read_round_trips_verbatim() {
    let f = fixture();
    let source = "# Auth\n\nSome **bold** text and `code`.\n";
    f.store
        .write("design/auth.md".into(), source.into(), None)
        .unwrap();

    assert_eq!(f.store.read("design/auth.md".into()).unwrap(), source);
    assert_eq!(paths(&f.store), ["design/auth.md"]);
}

#[test]
fn first_write_creates_ref_and_subsequent_writes_build_history() {
    let f = fixture();
    assert!(f.store.list_pages().unwrap().is_empty());

    f.store
        .write("notes.md".into(), "one\n".into(), None)
        .unwrap();
    f.store
        .write("notes.md".into(), "two\n".into(), None)
        .unwrap();

    assert_eq!(f.store.read("notes.md".into()).unwrap(), "two\n");
    assert_eq!(f.store.history("notes.md".into()).unwrap().len(), 2);
}

/// The prime invariant: docs live entirely outside the checkout.
#[test]
fn writing_docs_leaves_working_tree_and_index_untouched() {
    let f = fixture();
    f.store
        .write("design/auth.md".into(), "# Auth\n".into(), None)
        .unwrap();

    let status = f.git.text(&["status", "--porcelain"]).unwrap();
    assert_eq!(
        status, "",
        "docs must not appear in the working tree or index"
    );

    let tracked = f.git.text(&["ls-files"]).unwrap();
    assert_eq!(tracked, "", "docs must not be staged");

    let entries: Vec<String> = std::fs::read_dir(f.git.root.as_path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().to_string())
        .filter(|name| name != ".git")
        .collect();
    assert!(entries.is_empty(), "docs must not touch the filesystem");
}

#[test]
fn delete_removes_page() {
    let f = fixture();
    f.store.write("a.md".into(), "a\n".into(), None).unwrap();
    f.store.write("b.md".into(), "b\n".into(), None).unwrap();

    f.store.delete("a.md".into()).unwrap();

    assert_eq!(paths(&f.store), ["b.md"]);
}

#[test]
fn annotation_round_trips_on_a_commit() {
    let f = fixture();
    let head = f.git.text(&["rev-parse", "HEAD"]).unwrap();

    assert_eq!(f.store.annotation(head.clone()), None);
    f.store
        .set_annotation(head.clone(), "why we did this\n".into())
        .unwrap();

    // `git notes show` trims, so compare against the trimmed form.
    assert_eq!(f.store.annotation(head).as_deref(), Some("why we did this"));
}

/// A doc store keyed by synthetic anchors would lose data here. Ours must not:
/// gc collects unreachable objects, and prune deletes notes whose anchor is
/// gone. Pages live in a reachable tree outside refs/notes/, so they survive.
#[test]
fn pages_survive_garbage_collection_and_notes_prune() {
    let f = fixture();
    f.store
        .write("design/auth.md".into(), "# Auth\n".into(), None)
        .unwrap();

    f.git.run(&["gc", "--prune=now", "--quiet"]).unwrap();
    f.git.run(&["notes", "--ref=annotations", "prune"]).unwrap();

    assert_eq!(f.store.read("design/auth.md".into()).unwrap(), "# Auth\n");
}

#[test]
fn concurrent_write_loses_the_race_instead_of_clobbering() {
    let f = fixture();
    f.store
        .write("a.md".into(), "original\n".into(), None)
        .unwrap();
    let stale = f.git.resolve(PAGES_REF).unwrap();

    // Someone else advances the ref behind our back.
    f.store
        .write("b.md".into(), "other writer\n".into(), None)
        .unwrap();

    // A write built on the stale tip must be rejected by the CAS guard.
    let commit = commit_onto(&f.git, &stale, "a.md", "clobber\n");
    assert!(f
        .git
        .run(&["update-ref", PAGES_REF, &commit, &stale])
        .is_err());

    // The other writer's page is still there.
    assert_eq!(f.store.read("b.md".into()).unwrap(), "other writer\n");
}

#[test]
fn expected_blob_rejects_a_stale_write() {
    let f = fixture();
    f.store.write("a.md".into(), "one\n".into(), None).unwrap();
    let (content, blob) = f.store.read_with_blob("a.md").unwrap();
    assert_eq!(content, "one\n");

    // Someone else edits the same page after we read it.
    f.store.write("a.md".into(), "two\n".into(), None).unwrap();

    let error = f
        .store
        .write_expecting("a.md", "mine\n", None, Some(&blob))
        .unwrap_err();
    assert!(matches!(error, StoreError::Stale { .. }));
    assert_eq!(f.store.read("a.md".into()).unwrap(), "two\n");
}

#[test]
fn expected_blob_ignores_changes_to_other_pages() {
    let f = fixture();
    f.store.write("a.md".into(), "one\n".into(), None).unwrap();
    let (_, blob) = f.store.read_with_blob("a.md").unwrap();

    f.store
        .write("b.md".into(), "other\n".into(), None)
        .unwrap();

    f.store
        .write_expecting("a.md", "mine\n", None, Some(&blob))
        .unwrap();
    assert_eq!(f.store.read("a.md".into()).unwrap(), "mine\n");
}

#[test]
fn expected_blob_rejects_a_deleted_page() {
    let f = fixture();
    f.store.write("a.md".into(), "one\n".into(), None).unwrap();
    let (_, blob) = f.store.read_with_blob("a.md").unwrap();
    f.store.delete("a.md".into()).unwrap();

    let error = f
        .store
        .write_expecting("a.md", "mine\n", None, Some(&blob))
        .unwrap_err();
    assert!(matches!(error, StoreError::Stale { .. }));
}

#[test]
fn unchanged_write_and_missing_delete_add_no_commit() {
    let f = fixture();
    f.store.write("a.md".into(), "one\n".into(), None).unwrap();
    let tip = f.git.resolve(PAGES_REF).unwrap();

    let changed = f
        .store
        .write_expecting("a.md", "one\n", None, None)
        .unwrap();
    assert!(!changed);
    f.store.delete("missing.md".into()).unwrap();

    assert_eq!(f.git.resolve(PAGES_REF).unwrap(), tip);
}

#[test]
fn replace_requires_a_unique_match_unless_all() {
    let f = fixture();
    f.store
        .write("a.md".into(), "one two\ntwo three\n".into(), None)
        .unwrap();

    let error = f
        .store
        .replace("a.md", "two", "2", false, None)
        .unwrap_err();
    assert!(matches!(error, StoreError::Replace { .. }));
    let error = f
        .store
        .replace("a.md", "four", "4", false, None)
        .unwrap_err();
    assert!(matches!(error, StoreError::Replace { .. }));
    let error = f.store.replace("a.md", "", "x", true, None).unwrap_err();
    assert!(matches!(error, StoreError::Replace { .. }));
    assert_eq!(f.store.read("a.md".into()).unwrap(), "one two\ntwo three\n");

    assert_eq!(
        f.store
            .replace("a.md", "one two", "1 2", false, None)
            .unwrap(),
        1
    );
    assert_eq!(f.store.read("a.md".into()).unwrap(), "1 2\ntwo three\n");

    assert_eq!(f.store.replace("a.md", "t", "T", true, None).unwrap(), 2);
    assert_eq!(f.store.read("a.md".into()).unwrap(), "1 2\nTwo Three\n");
}

#[test]
fn rename_moves_a_page_in_one_commit() {
    let f = fixture();
    f.store.write("a.md".into(), "body\n".into(), None).unwrap();
    let tip = f.git.resolve(PAGES_REF).unwrap();

    let moves = f.store.rename("a.md", "notes/b.md", None).unwrap();
    assert_eq!(moves, [("a.md".to_string(), "notes/b.md".to_string())]);

    let paths: Vec<String> = f
        .store
        .list_pages()
        .unwrap()
        .into_iter()
        .map(|page| page.path)
        .collect();
    assert_eq!(paths, ["notes/b.md"]);
    assert_eq!(f.store.read("notes/b.md".into()).unwrap(), "body\n");
    let parent = f
        .git
        .text(&["rev-parse", &format!("{PAGES_REF}^")])
        .unwrap();
    assert_eq!(parent, tip);
}

#[test]
fn rename_moves_a_folder() {
    let f = fixture();
    f.store
        .write("design/a.md".into(), "a\n".into(), None)
        .unwrap();
    f.store
        .write("design/sub/b.md".into(), "b\n".into(), None)
        .unwrap();
    f.store
        .write("designs.md".into(), "not in the folder\n".into(), None)
        .unwrap();

    f.store.rename("design/", "archive/design", None).unwrap();

    let paths: Vec<String> = f
        .store
        .list_pages()
        .unwrap()
        .into_iter()
        .map(|page| page.path)
        .collect();
    assert_eq!(
        paths,
        [
            "archive/design/a.md",
            "archive/design/sub/b.md",
            "designs.md"
        ]
    );
}

#[test]
fn rename_refuses_missing_sources_and_taken_destinations() {
    let f = fixture();
    f.store.write("a.md".into(), "a\n".into(), None).unwrap();
    f.store.write("b.md".into(), "b\n".into(), None).unwrap();

    let error = f.store.rename("nope.md", "c.md", None).unwrap_err();
    assert!(matches!(error, StoreError::NotFound(_)));
    let error = f.store.rename("a.md", "b.md", None).unwrap_err();
    assert!(matches!(error, StoreError::Exists(_)));
    assert_eq!(f.store.read("b.md".into()).unwrap(), "b\n");
}

#[test]
fn reading_a_missing_page_or_a_folder_is_not_found() {
    let f = fixture();
    let error = f.store.read("a.md".into()).unwrap_err();
    assert!(matches!(error, StoreError::NotFound(_)));

    f.store
        .write("design/a.md".into(), "a\n".into(), None)
        .unwrap();
    let error = f.store.read("nope.md".into()).unwrap_err();
    assert!(matches!(error, StoreError::NotFound(_)));
    let error = f.store.read("design".into()).unwrap_err();
    assert!(matches!(error, StoreError::NotFound(_)));
}

#[test]
fn glob_characters_in_a_path_are_literal() {
    let f = fixture();
    f.store
        .write("a*.md".into(), "star\n".into(), None)
        .unwrap();
    f.store.write("ab.md".into(), "ab\n".into(), None).unwrap();

    assert_eq!(f.store.read("a*.md".into()).unwrap(), "star\n");
    let error = f.store.read("a?.md".into()).unwrap_err();
    assert!(matches!(error, StoreError::NotFound(_)));
}

#[test]
fn list_entries_reports_blob_and_size() {
    let f = fixture();
    f.store
        .write("b/two.md".into(), "two\n".into(), None)
        .unwrap();
    f.store.write("a.md".into(), "one\n".into(), None).unwrap();

    let entries = f.store.list_entries().unwrap();
    let paths: Vec<&str> = entries.iter().map(|entry| entry.path.as_str()).collect();
    assert_eq!(paths, ["a.md", "b/two.md"]);
    assert_eq!(entries[0].size, 4);
    let (_, blob) = f.store.read_with_blob("a.md").unwrap();
    assert_eq!(entries[0].blob, blob);
}

#[test]
fn custom_messages_replace_the_default_subject() {
    let f = fixture();
    let subject = |f: &Fixture| {
        f.git
            .text(&["log", "-1", "--format=%s", PAGES_REF])
            .unwrap()
    };

    f.store
        .write_expecting("a.md", "one\n", Some("why a".into()), None)
        .unwrap();
    assert_eq!(subject(&f), "why a");
    f.store
        .replace("a.md", "one", "two", false, Some("why replace".into()))
        .unwrap();
    assert_eq!(subject(&f), "why replace");
    f.store
        .rename("a.md", "b.md", Some("why move".into()))
        .unwrap();
    assert_eq!(subject(&f), "why move");
    f.store
        .delete_with_message("b.md", Some("why delete".into()))
        .unwrap();
    assert_eq!(subject(&f), "why delete");
}

#[test]
fn diverged_edits_merge_cleanly() {
    let f = fixture();
    f.store
        .write(
            "doc.md".into(),
            "line one\nline two\nline three\n".into(),
            None,
        )
        .unwrap();
    let base = f.git.resolve(PAGES_REF).unwrap();

    // Local edits the middle line.
    f.store
        .write(
            "doc.md".into(),
            "line one\nLOCAL\nline three\n".into(),
            None,
        )
        .unwrap();
    let ours = f.git.resolve(PAGES_REF).unwrap();

    // A "remote" appends, branching from the same base.
    let theirs = commit_onto(
        &f.git,
        &base,
        "doc.md",
        "line one\nline two\nline three\nREMOTE\n",
    );
    f.git
        .run(&["update-ref", &pages_upstream("origin"), &theirs, ""])
        .unwrap();
    f.git.run(&["update-ref", PAGES_REF, &ours, &ours]).unwrap();

    assert!(matches!(
        f.store.merge_from_upstream(None).unwrap(),
        MergeResult::Merged
    ));

    let merged = f.store.read("doc.md".into()).unwrap();
    assert!(merged.contains("LOCAL"), "our edit survived");
    assert!(merged.contains("REMOTE"), "their edit survived");
}

#[test]
fn overlapping_edits_report_conflict_with_three_stages() {
    let f = fixture();
    f.store
        .write(
            "doc.md".into(),
            "line one\nline two\nline three\n".into(),
            None,
        )
        .unwrap();
    let base = f.git.resolve(PAGES_REF).unwrap();

    f.store
        .write("doc.md".into(), "line one\nOURS\nline three\n".into(), None)
        .unwrap();

    let theirs = commit_onto(&f.git, &base, "doc.md", "line one\nTHEIRS\nline three\n");
    f.git
        .run(&["update-ref", &pages_upstream("origin"), &theirs, ""])
        .unwrap();

    let MergeResult::Conflicted { conflicts } = f.store.merge_from_upstream(None).unwrap() else {
        panic!("expected a conflict");
    };

    assert_eq!(
        conflicts
            .iter()
            .map(|c| c.path.as_str())
            .collect::<Vec<_>>(),
        ["doc.md"]
    );
    let conflict = &conflicts[0];
    assert!(conflict.base.is_some());
    assert!(conflict.ours.is_some());
    assert!(conflict.theirs.is_some());

    // The stage blobs must be real, readable content, which is what lets the UI
    // show base/ours/theirs rather than conflict markers.
    let their_side = f
        .git
        .text(&["cat-file", "-p", conflict.theirs.as_ref().unwrap()])
        .unwrap();
    assert!(their_side.contains("THEIRS"));
}

#[test]
fn diff_shows_changes_between_a_revision_and_the_current_tip() {
    let f = fixture();
    f.store
        .write("doc.md".into(), "line one\nline two\n".into(), None)
        .unwrap();
    let first = f.store.history("doc.md".into()).unwrap()[0].id.clone();

    f.store
        .write("doc.md".into(), "line one\nline two changed\n".into(), None)
        .unwrap();

    let diff = f.store.diff("doc.md".into(), first, None).unwrap();
    assert!(diff.contains("-line two"));
    assert!(diff.contains("+line two changed"));
}

#[test]
fn diff_against_the_current_tip_is_empty() {
    let f = fixture();
    f.store
        .write("doc.md".into(), "unchanged\n".into(), None)
        .unwrap();
    let revision = f.store.history("doc.md".into()).unwrap()[0].id.clone();

    assert_eq!(f.store.diff("doc.md".into(), revision, None).unwrap(), "");
}

/// `docs/STORAGE.md` §4: a page commit records which repo commit was checked
/// out when it was written, as a trailer stock git tooling can read back.
#[test]
fn page_commits_carry_the_repo_commit_trailer() {
    let f = fixture();
    let head = f.git.text(&["rev-parse", "HEAD"]).unwrap();

    f.store
        .write("doc.md".into(), "# Doc\n".into(), None)
        .unwrap();

    let trailer = f
        .git
        .text(&[
            "log",
            "-1",
            "--format=%(trailers:key=Repo-Commit,valueonly)",
            PAGES_REF,
        ])
        .unwrap();
    assert_eq!(trailer, head);
}

/// An unborn branch has no HEAD to stamp, and writing a page must still work.
#[test]
fn writing_works_on_an_unborn_branch() {
    let dir = tempfile::Builder::new()
        .prefix("repo-docs-unborn-")
        .tempdir()
        .unwrap();
    let git = Git::new(dir.path());
    git.run(&["init", "--quiet", "."]).unwrap();
    git.run(&["config", "user.email", "test@example.com"])
        .unwrap();
    git.run(&["config", "user.name", "Test"]).unwrap();

    let store = DocStore::open(dir.path());
    store
        .write("doc.md".into(), "# Doc\n".into(), None)
        .unwrap();

    assert_eq!(store.read("doc.md".into()).unwrap(), "# Doc\n");
    let trailer = git
        .text(&[
            "log",
            "-1",
            "--format=%(trailers:key=Repo-Commit,valueonly)",
            PAGES_REF,
        ])
        .unwrap();
    assert_eq!(trailer, "", "nothing to stamp before the first commit");
}

#[test]
fn last_modified_times_reports_the_newest_commit_per_page() {
    let f = fixture();
    f.store.write("a.md".into(), "one\n".into(), None).unwrap();
    f.store.write("b.md".into(), "one\n".into(), None).unwrap();
    f.store.write("a.md".into(), "two\n".into(), None).unwrap();

    let times = f.store.last_modified_times().unwrap();
    assert_eq!(times.len(), 2);
    assert!(times[&"a.md".to_string()] >= times[&"b.md".to_string()]);
}

/// `ls-tree` and `log --name-only` C-quote non-ASCII paths by default, which
/// would hand back `"notes/caf\303\251.md"`, a path no later `cat-file` can
/// resolve, and a key `last_modified_times` could never match.
#[test]
fn non_ascii_page_paths_round_trip() {
    let f = fixture();
    let path = "notes/café/naïve.md";
    f.store.write(path.into(), "# Café\n".into(), None).unwrap();

    assert_eq!(paths(&f.store), [path]);
    assert_eq!(f.store.read(path.into()).unwrap(), "# Café\n");
    assert_eq!(f.store.info(path.into()).unwrap().path, path);
    assert!(f.store.last_modified_times().unwrap().contains_key(path));

    f.store.delete(path.into()).unwrap();
    assert!(paths(&f.store).is_empty());
}

/// The same trap for a path git would quote for a different reason: a space is
/// safe, a quote and a backslash are not.
#[test]
fn awkward_page_paths_round_trip() {
    let f = fixture();
    let path = "my notes/a \"quoted\" \\ page.md";
    f.store.write(path.into(), "body\n".into(), None).unwrap();

    assert_eq!(paths(&f.store), [path]);
    assert_eq!(f.store.read(path.into()).unwrap(), "body\n");
}

#[test]
fn configure_remote_scopes_the_mirror_ref_per_remote() {
    let f = fixture();
    f.store.configure_remote(None).unwrap();
    f.store.configure_remote(Some("upstream".into())).unwrap();

    let specs = |remote: &str| {
        f.git
            .text(&["config", "--get-all", &format!("remote.{remote}.fetch")])
            .unwrap()
    };
    assert!(specs("origin").contains("+refs/docs/pages:refs/docs/remotes/origin/pages"));
    // The second remote must not fetch into the first's mirror.
    assert!(specs("upstream").contains("+refs/docs/pages:refs/docs/remotes/upstream/pages"));
    assert!(!specs("upstream").contains("remotes/origin/pages"));
}

#[test]
fn configure_remote_does_not_duplicate_existing_refspecs() {
    let f = fixture();
    // A spec that merely *contains* ours as a substring must not be mistaken
    // for it.
    f.git
        .run(&[
            "config",
            "--add",
            "remote.origin.fetch",
            "+refs/docs/pages:refs/docs/remotes/origin/pages-old",
        ])
        .unwrap();

    f.store.configure_remote(None).unwrap();
    f.store.configure_remote(None).unwrap();

    let specs = f
        .git
        .text(&["config", "--get-all", "remote.origin.fetch"])
        .unwrap();
    let ours = format!("+{PAGES_REF}:{}", pages_upstream("origin"));
    assert_eq!(
        specs.lines().filter(|line| *line == ours).count(),
        1,
        "added once, not on every call"
    );
}

/// A second remote's pages must not be merged out of the first one's mirror.
#[test]
fn merge_reads_the_named_remotes_mirror() {
    let f = fixture();
    f.store
        .write("doc.md".into(), "base\n".into(), None)
        .unwrap();
    let base = f.git.resolve(PAGES_REF).unwrap();

    let theirs = commit_onto(&f.git, &base, "doc.md", "base\nfrom upstream\n");
    f.git
        .run(&["update-ref", &pages_upstream("upstream"), &theirs, ""])
        .unwrap();

    // Nothing fetched from origin, so the default remote has nothing to merge.
    assert!(matches!(
        f.store.merge_from_upstream(None).unwrap(),
        MergeResult::UpToDate
    ));
    assert_eq!(f.store.read("doc.md".into()).unwrap(), "base\n");

    assert!(matches!(
        f.store
            .merge_from_upstream(Some("upstream".into()))
            .unwrap(),
        MergeResult::FastForwarded
    ));
    assert_eq!(
        f.store.read("doc.md".into()).unwrap(),
        "base\nfrom upstream\n"
    );
}

#[test]
fn opening_a_non_repository_errors() {
    let dir = tempfile::Builder::new()
        .prefix("repo-docs-bare-")
        .tempdir()
        .unwrap();
    assert!(DocStore::new(dir.path().display().to_string()).is_err());
    assert!(!rd_core::is_repository(dir.path().display().to_string()));
}

#[test]
fn tree_groups_pages_by_path_prefix() {
    use rd_core::{build_tree, Page};

    let pages = vec![
        Page::new("top.md"),
        Page::new("design/auth.md"),
        Page::new("design/api/v1.md"),
    ];
    let tree = build_tree(pages, vec!["empty/".into()]);

    // Folders first (sorted), then loose pages.
    let names: Vec<&str> = tree.iter().map(|node| node.name.as_str()).collect();
    assert_eq!(names, ["design", "empty", "top"]);

    let design = &tree[0];
    let children = design.children.as_ref().unwrap();
    assert_eq!(children[0].name, "api");
    assert_eq!(children[1].name, "auth");
    assert!(children[1].page.is_some());

    // A pending folder is a placeholder with no pages under it.
    assert!(tree[1].children.as_ref().unwrap().is_empty());
}
