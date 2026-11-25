# radish

A macOS app for writing and reading markdown that lives **in** a git repo but never in its working tree. Docs are stored in their own refs, so they travel with the repo, show up in no `git status`, and add no noise to a PR diff.

Inspiration:

- https://lobste.rs/s/vmrnyd/git_notes_git_s_coolest_most_unloved
- https://tylercipriani.com/blog/2022/11/19/git-notes-gits-coolest-most-unloved-feature/

There are two front ends over one storage layer: the app, and `rd`, a terminal client. The storage layer itself is a Rust crate (`crates/rd-core`) that both link — `rd` as an ordinary dependency, the app through UniFFI — so the two can't drift apart.

## Build

```sh
axo core      # build the Rust core, regenerate the Swift bindings
axo build     # axo core, then strudel build -> .build/dist/Radish.app
axo run       # build and launch
axo test      # cargo test
axo cli       # just the `rd` binary
```

`ARCHS="arm64 x86_64" axo core` produces a universal core.

The markdown editor comes from [Crumpet](https://github.com/octavore/crumpet), a remote package dependency. It is upstream — we don't patch it from here.

## `rd`

```sh
rd                       # list every doc
rd list -t               # list, newest edited first
rd cat design/auth.md    # print one (colorized on a tty)
rd design/auth.md        # shorthand for `rd cat`
rd edit design/auth.md   # $EDITOR; or `- ` for stdin, or a file path
rd rm design/auth.md
rd grep -i stateless     # search every doc. `rd grep --help` to see all flags.
rd grep -l auth design   # only docs under design/, paths only
rd fmt [path] [--check]  # reformat one doc, or all, with rumdl
rd export [dir]          # dump every doc to a directory
rd .                     # open this repo in the app
rd install               # symlink ~/.local/bin/rd
rd agent                 # usage notes for AI agents
```

`rd` ships inside `Radish.app/Contents/MacOS/`; Radish ▸ Install 'rd' Command Line Tool symlinks it onto your PATH.

### Shell completion

`rd` completes subcommands and doc paths (for `cat`, `edit`, `rm`, `mv`, `grep`, and others). Add one line to your shell's rc file:

```sh
source <(COMPLETE=zsh rd)               # ~/.zshrc
source <(COMPLETE=bash rd)              # ~/.bashrc
COMPLETE=fish rd | source               # ~/.config/fish/config.fish
```

Doc paths come from the repo in the current directory, one folder level at a time.

## Where the docs are

Two stores. The storage spec (`rd cat docs/STORAGE.md`) explains why they differ; the short version is that only one of them can safely be a real git note.

| | Ref | Keyed by |
|---|---|---|
| **Pages** — free-standing docs | `refs/docs/pages` | human path (`design/auth.md`) |
| **Annotations** — commentary on a commit | `refs/notes/annotations` | the commit's OID |

Neither is fetched or pushed by default. That is git's behavior for notes and for any ref outside `refs/heads/*` — and it is the most common way a doc store silently diverges.

---

## Working with `refs/docs/pages` from the command line

The app is not required. `refs/docs/pages` is an ordinary commit pointing at an ordinary tree, so ordinary git commands work on it — you just have to name the ref, because nothing about it is in your checkout.

### Reading

```sh
# List every page
git ls-tree -r --name-only refs/docs/pages

# Read one
git show refs/docs/pages:design/auth.md

# Search all pages without checking anything out
git grep -n "stateless" refs/docs/pages

# History of a single page
git log --oneline refs/docs/pages -- design/auth.md

# What changed in the last edit
git log -p -1 refs/docs/pages -- design/auth.md

# Diff any two revisions
git diff <old-commit> <new-commit> -- design/auth.md

# Which repo commit was HEAD when a page was last written
git log -1 --format='%(trailers:key=Repo-Commit,valueonly)' refs/docs/pages -- design/auth.md
```

### Writing

There is no `git add` for a page — that would stage it into the working tree, which is exactly what we're avoiding. Instead build a tree in a **temporary index**, commit it, and move the ref.

Drop this in your shell:

```sh
# NB: the variable is `doc`, not `path` — in zsh, `path` is tied to `PATH`, so
# `local path=…` would wipe your PATH and every command below would vanish.
docs-write() {  # docs-write <path> < content
  local doc="$1" old blob tree commit head msg
  export GIT_INDEX_FILE="$(mktemp -u)"   # never the repo's real index
  old="$(git rev-parse --verify --quiet refs/docs/pages || true)"
  head="$(git rev-parse --verify --quiet HEAD || true)"   # empty on an unborn branch
  blob="$(git hash-object -w --stdin)"
  if [ -n "$old" ]; then
    git read-tree "$old"
    git update-index --add --cacheinfo "100644,$blob,$doc"
    tree="$(git write-tree)"
    msg="docs: update $doc"
  else
    git update-index --add --cacheinfo "100644,$blob,$doc"
    tree="$(git write-tree)"
    msg="docs: create $doc"
  fi
  [ -n "$head" ] && msg="$(printf '%s\n\nRepo-Commit: %s' "$msg" "$head")"
  if [ -n "$old" ]; then
    commit="$(git commit-tree "$tree" -p "$old" -m "$msg")"
    git update-ref refs/docs/pages "$commit" "$old"   # compare-and-swap
  else
    commit="$(git commit-tree "$tree" -m "$msg")"
    git update-ref refs/docs/pages "$commit"
  fi
  rm -f "$GIT_INDEX_FILE"; unset GIT_INDEX_FILE
}

docs-write design/auth.md <<'EOF'
# Auth

Sessions are stateless.
EOF
```

Two details in there are load-bearing, and the app does the same thing:

- **`GIT_INDEX_FILE`** points git at a throwaway index, so your real staged changes are untouched. Without it, `update-index` would stage the page into your actual checkout.
- **`git update-ref <ref> <new> <old>`** is a compare-and-swap: it aborts if the ref no longer equals `<old>`. That's what stops a concurrent writer from being silently clobbered. Never drop the third argument on an update.

Note for zsh users: quote your expansions. zsh doesn't word-split unquoted parameters, so a `${old:+-p $old}` shortcut collapses into a *single* argument and git rejects it with a confusing "not a valid object name".

### Deleting

Same recipe, with `git update-index --force-remove <path>` instead of `--add`.

### Syncing

```sh
# One-time: teach the remote about the doc refs
git config --add remote.origin.fetch '+refs/docs/pages:refs/docs/remotes/origin/pages'
git config --add remote.origin.fetch '+refs/notes/annotations:refs/notes/remotes/origin/annotations'

git fetch origin
git push --force-with-lease=refs/docs/pages origin refs/docs/pages:refs/docs/pages
```

Always `--force-with-lease`, never a bare `--force`: the lease refuses to overwrite a remote that moved since your last fetch, which is the network-level version of the compare-and-swap above.

To reconcile a diverged store *without* touching your working tree, use `merge-tree`, which does a full three-way merge in memory:

```sh
git merge-tree --write-tree refs/docs/pages refs/docs/remotes/origin/pages
```

It prints the merged tree OID on success. On a conflict it exits 1 and lists the conflicted path at stages 1/2/3 (base / ours / theirs) — three blob OIDs you can `git cat-file -p` directly. Commit the merged tree with `git commit-tree <tree> -p <ours> -p <theirs>` and compare-and-swap the ref.

---

## Annotations (real git notes)

These are ordinary notes, so the porcelain works:

```sh
git notes --ref=annotations add -m "Why we did this" <commit>
git notes --ref=annotations show <commit>
git notes --ref=annotations list

# Render them inline in the log
git log --notes=annotations
```

## ⚠️ Never run `git notes prune` in a repo using this app

It deletes notes whose annotated object no longer exists. Annotations are keyed by real commits, so they're normally safe — but if a commit gets rebased away, prune will silently delete your commentary on it. Prefer `git notes copy <old> <new>` to relocate it.

This is also the reason **pages are not stored as notes**. Keying a page by a synthetic anchor object leaves that anchor unreachable in the object graph; `git gc` collects it, and `git notes prune` then deletes the page hanging off it — two routine maintenance commands that quietly destroy the store. Pages live in a reachable tree under `refs/docs/` precisely to sit outside that blast radius. `docs/STORAGE.md` §2 has the demonstration.


## Credits

<a href="https://www.flaticon.com/free-icons/book" title="book icons">Book icons created by Freepik - Flaticon</a>
