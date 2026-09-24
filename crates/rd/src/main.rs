//! `rd`: read and write a repository's docs from a terminal.
//!
//! Every storage operation goes through `rd_core`, the same crate the RepoDocs
//! app links through UniFFI, so the CLI and the GUI stay in sync.

mod agent;
mod complete;
mod grep;
mod markdown;
mod open;
mod relative;
mod suggest;

use std::io::{IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{anyhow, bail, Context, Result};
use clap::{CommandFactory, Parser, Subcommand};
use clap_complete::{ArgValueCompleter, CompleteEnv};
use clml::{ceprintln, cformat};
use rd_core::{DocStore, Git, StoreError};

#[derive(Parser)]
#[command(
    name = "rd",
    about = "Read and write docs stored in refs/docs/pages, outside the working tree",
    disable_help_subcommand = true,
    subcommand_negates_reqs = true
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// List the docs in the current repo
    List {
        /// Sort newest-modified first
        #[arg(short = 't', long = "by-date")]
        by_date: bool,
        /// Print a JSON array of {path, blob, size, modified} (modified is
        /// Unix seconds, or null)
        #[arg(long)]
        json: bool,
    },
    /// Print one or more docs; several get a '==> path <==' header each
    Cat {
        #[arg(
            required_unless_present = "all",
            add = ArgValueCompleter::new(complete::doc_path)
        )]
        paths: Vec<String>,
        /// Print every doc
        #[arg(long, conflicts_with = "paths")]
        all: bool,
        /// Number each line (turns off terminal colors)
        #[arg(short = 'n', long = "line-numbers")]
        line_numbers: bool,
    },
    /// Edit a doc: $EDITOR if no file, '-' for stdin, or from a file
    Edit {
        #[arg(add = ArgValueCompleter::new(complete::doc_path))]
        path: String,
        /// A file to read the new content from, or '-' for stdin
        file: Option<String>,
        /// Fail unless the doc's current blob OID is this one (`rd cat` prints
        /// it to stderr)
        #[arg(long, value_name = "OID")]
        expect: Option<String>,
        /// Commit message (default: "docs: update <path>")
        #[arg(short = 'm', long)]
        message: Option<String>,
    },
    /// Replace an exact string in a doc; it must occur once unless --all
    Replace {
        #[arg(add = ArgValueCompleter::new(complete::doc_path))]
        path: String,
        /// The exact text to find
        #[arg(allow_hyphen_values = true)]
        old: String,
        /// The text to put in its place
        #[arg(allow_hyphen_values = true)]
        new: String,
        /// Replace every occurrence instead of requiring exactly one
        #[arg(long)]
        all: bool,
        /// Commit message (default: "docs: update <path>")
        #[arg(short = 'm', long)]
        message: Option<String>,
    },
    /// Move a doc, or every doc under a folder, in one commit
    #[command(alias = "rename")]
    Mv {
        #[arg(add = ArgValueCompleter::new(complete::doc_path))]
        from: String,
        #[arg(add = ArgValueCompleter::new(complete::doc_path))]
        to: String,
        /// Commit message (default: "docs: move <from> to <to>")
        #[arg(short = 'm', long)]
        message: Option<String>,
    },
    /// Delete a doc
    #[command(alias = "delete")]
    Rm {
        #[arg(add = ArgValueCompleter::new(complete::doc_path))]
        path: String,
        /// Commit message (default: "docs: delete <path>")
        #[arg(short = 'm', long)]
        message: Option<String>,
    },
    /// Reformat a doc, or every doc, with rumdl
    Fmt {
        /// A doc to format; omit to format every doc
        #[arg(add = ArgValueCompleter::new(complete::doc_path))]
        path: Option<String>,
        /// Report which docs would change without writing them
        #[arg(long)]
        check: bool,
    },
    /// Search doc content for a regex
    Grep(grep::GrepArgs),
    /// Dump every doc to a directory (default: a fresh tmpdir)
    Export { dir: Option<PathBuf> },
    /// Open a doc, or '.' for the current repo, in the RepoDocs app
    Open {
        #[arg(add = ArgValueCompleter::new(complete::doc_path))]
        path: String,
    },
    /// Usage notes for AI agents editing docs via rd
    Agent,
    /// (Re)install this helper to ~/.local/bin/rd
    Install,

    /// `rd design/auth.md` is shorthand for `rd cat design/auth.md`, and `rd .`
    /// for `rd open .`.
    #[command(external_subcommand)]
    Shorthand(Vec<String>),
}

fn main() {
    if let Err(error) = run() {
        // `{error:#}` prints the anyhow context chain on one line.
        ceprintln!("<red>rd:</> {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    // When a shell's completion hook sets COMPLETE, print candidates and exit.
    CompleteEnv::with_factory(Cli::command).complete();

    let cli = Cli::parse();

    // These two need no repository, so they come before discovery.
    match &cli.command {
        Some(Cmd::Agent) => {
            print!("{}", agent::HELP);
            return Ok(());
        },
        Some(Cmd::Install) => return install(),
        _ => {},
    }

    let cwd = std::env::current_dir().context("reading the current directory")?;
    let root = Git::discover(&cwd).ok_or_else(|| anyhow!("not inside a git repository"))?;
    let store = DocStore::open(&root);

    let result = match cli.command {
        None => list(&store, false, false),
        Some(Cmd::List { by_date, json }) => list(&store, by_date, json),
        Some(Cmd::Cat {
            paths,
            all,
            line_numbers,
        }) => cat(&store, &paths, all, line_numbers),
        Some(Cmd::Edit {
            path,
            file,
            expect,
            message,
        }) => edit(&store, &path, file.as_deref(), expect.as_deref(), message),
        Some(Cmd::Replace {
            path,
            old,
            new,
            all,
            message,
        }) => replace(&store, &path, &old, &new, all, message),
        Some(Cmd::Mv { from, to, message }) => rename(&store, &from, &to, message),
        Some(Cmd::Rm { path, message }) => remove(&store, &path, message),
        Some(Cmd::Fmt { path, check }) => format(&store, path.as_deref(), check),
        Some(Cmd::Grep(args)) => {
            // Like grep: 0 on a match, 1 on no match, 2 on an error.
            match grep::run(&store, &args) {
                Ok(true) => Ok(()),
                Ok(false) => std::process::exit(1),
                Err(error) => {
                    ceprintln!("<red>rd:</> {error:#}");
                    std::process::exit(2);
                },
            }
        },
        Some(Cmd::Export { dir }) => export(&store, dir),
        Some(Cmd::Open { path }) => open_page(&store, &root, &path),
        Some(Cmd::Shorthand(args)) => {
            if args == ["."] {
                open::repo(&root)
            } else {
                cat(&store, &args, false, false)
            }
        },
        Some(Cmd::Agent | Cmd::Install) => unreachable!("handled above"),
    };
    result.map_err(|error| with_suggestions(&store, error))
}

/// Adds "did you mean" candidates to a `StoreError::NotFound`, and passes any
/// other error through unchanged.
fn with_suggestions(store: &DocStore, error: anyhow::Error) -> anyhow::Error {
    let Some(StoreError::NotFound(missing)) = error.downcast_ref::<StoreError>() else {
        return error;
    };
    let paths: Vec<String> = store
        .list_pages()
        .unwrap_or_default()
        .into_iter()
        .map(|page| page.path)
        .collect();
    let matches = suggest::close_matches(missing, &paths);
    if matches.is_empty() {
        return anyhow!("{error}; see 'rd list'");
    }
    anyhow!("{error}; did you mean {}?", matches.join(", "))
}

fn list(store: &DocStore, by_date: bool, json: bool) -> Result<()> {
    if json {
        return list_json(store, by_date);
    }
    let pages = store.list_pages()?;
    // Nothing on stdout, so a script reading paths sees an empty list.
    if pages.is_empty() {
        eprintln!("rd: no docs yet");
        return Ok(());
    }
    if !by_date {
        for page in pages {
            println!("{}", page.path);
        }
        return Ok(());
    }

    let modified = store.last_modified_times()?;
    let mut dated: Vec<_> = pages
        .into_iter()
        .map(|page| {
            let date = modified.get(&page.path).copied();
            (page, date)
        })
        .collect();
    // Newest first; undated pages (no commit touching them) sort last.
    dated.sort_by_key(|(_, date)| std::cmp::Reverse(*date));

    for (page, date) in dated {
        match date {
            Some(date) => {
                let ago = relative::describe(date);
                let path = page.path;
                println!("{}", cformat!("{path}  <dim>({ago})</>"));
            },
            None => println!("{}", page.path),
        }
    }
    Ok(())
}

/// `rd list --json`: one array, sorted by path or, with `by_date`, newest
/// first.
fn list_json(store: &DocStore, by_date: bool) -> Result<()> {
    let modified = store.last_modified_times()?;
    let seconds = |path: &str| {
        modified
            .get(path)
            .and_then(|date| date.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|elapsed| elapsed.as_secs())
    };
    let mut entries = store.list_entries()?;
    if by_date {
        entries.sort_by_key(|entry| std::cmp::Reverse(seconds(&entry.path)));
    }
    let rows: Vec<serde_json::Value> = entries
        .iter()
        .map(|entry| {
            serde_json::json!({
                "path": entry.path,
                "blob": entry.blob,
                "size": entry.size,
                "modified": seconds(&entry.path),
            })
        })
        .collect();
    println!("{}", serde_json::to_string_pretty(&rows)?);
    Ok(())
}

/// Prints one doc, several, or with `all` every doc. Every doc is read before
/// anything is printed, so a missing path fails with no partial output.
///
/// One doc prints bare, and when stdout is not a terminal its blob OID goes to
/// stderr for a later `rd edit --expect`. Several docs each get a
/// `==> path <==` header, which carries the blob OID when stdout is not a
/// terminal. `line_numbers` prefixes each line with its number and a tab, as
/// `cat -n` does, and skips the terminal colorizer.
fn cat(store: &DocStore, paths: &[String], all: bool, line_numbers: bool) -> Result<()> {
    let paths: Vec<String> = if all {
        store
            .list_pages()?
            .into_iter()
            .map(|page| page.path)
            .collect()
    } else {
        paths.to_vec()
    };
    if paths.is_empty() {
        eprintln!("rd: no docs yet");
        return Ok(());
    }
    let docs: Vec<(String, String, String)> = paths
        .into_iter()
        .map(|path| {
            let (content, blob) = store.read_with_blob(&path)?;
            Ok((path, content, blob))
        })
        .collect::<Result<_>>()?;

    let terminal = std::io::stdout().is_terminal();
    let render = |content: &str| {
        if line_numbers {
            number_lines(content)
        } else if terminal {
            markdown::colorize(content)
        } else {
            content.to_string()
        }
    };

    let mut out = std::io::stdout().lock();
    if let [(_, content, blob)] = docs.as_slice() {
        if !all {
            // `write!`, not `writeln!`: docs end in their own newline.
            write!(out, "{}", render(content))?;
            if !terminal {
                out.flush()?;
                eprintln!("rd: blob {blob} (pass to rd edit --expect to reject a stale write)");
            }
            return Ok(());
        }
    }
    for (index, (path, content, blob)) in docs.iter().enumerate() {
        if index > 0 {
            writeln!(out)?;
        }
        if terminal {
            let header = format!("==> {path} <==");
            writeln!(out, "{}", cformat!("<bold>{header}</>"))?;
        } else {
            writeln!(out, "==> {path} (blob {blob}) <==")?;
        }
        let body = render(content);
        write!(out, "{body}")?;
        if !body.is_empty() && !body.ends_with('\n') {
            writeln!(out)?;
        }
    }
    Ok(())
}

fn number_lines(content: &str) -> String {
    content
        .lines()
        .enumerate()
        .map(|(index, line)| format!("{:>6}\t{line}\n", index + 1))
        .collect()
}

/// Writes a page from `file`, from stdin when `file` is `-`, or by opening
/// `$EDITOR` on the page's current content when no file is given. Creates the
/// page if it doesn't exist yet, same as `DocStore::write`. There is no
/// separate "new" command.
///
/// With `expect`, the write is rejected unless the page's blob OID still equals
/// it. The `$EDITOR` path always guards against the OID it opened with.
fn edit(
    store: &DocStore,
    path: &str,
    file: Option<&str>,
    expect: Option<&str>,
    message: Option<String>,
) -> Result<()> {
    let (content, opened) = match file {
        Some("-") => {
            let mut buffer = String::new();
            std::io::stdin()
                .read_to_string(&mut buffer)
                .context("reading stdin")?;
            (buffer, None)
        },
        Some(file) => {
            let content =
                std::fs::read_to_string(file).with_context(|| format!("can't read {file}"))?;
            (content, None)
        },
        None => edit_interactively(store, path)?,
    };
    if store.write_expecting(path, &content, message, expect.or(opened.as_deref()))? {
        println!("wrote {path}");
    } else {
        println!("unchanged {path}");
    }
    Ok(())
}

/// Opens `$EDITOR` (falling back to `vi`) on a scratch file seeded with the
/// page's current content, if any, and returns what the editor left behind
/// along with the blob OID it started from.
fn edit_interactively(store: &DocStore, path: &str) -> Result<(String, Option<String>)> {
    // An editor with no terminal blocks forever or garbles output, which is how
    // an agent calling `rd edit <path>` from a non-interactive shell ends up.
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        bail!("no terminal for $EDITOR; pass '-' to read stdin, or a file to read from");
    }
    let editor = std::env::var("EDITOR").unwrap_or_else(|_| "vi".to_string());
    let (existing, opened) = match store.read_with_blob(path) {
        Ok((content, blob)) => (content, Some(blob)),
        // A new doc starts empty; any other failure is a real error.
        Err(StoreError::NotFound(_)) => (String::new(), None),
        Err(error) => return Err(error.into()),
    };

    let dir = tempfile::Builder::new().prefix("rd-edit-").tempdir()?;
    let name = Path::new(path)
        .file_name()
        .ok_or_else(|| anyhow!("{path} has no filename"))?;
    let scratch = dir.path().join(name);
    std::fs::write(&scratch, existing)?;

    // Through `sh -c` so $EDITOR can carry its own flags, as it commonly does.
    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("{editor} \"$1\""))
        .arg("sh")
        .arg(&scratch)
        .status()
        .with_context(|| format!("running {editor}"))?;
    if !status.success() {
        bail!(
            "{editor} exited with status {}",
            status.code().unwrap_or(-1)
        );
    }

    let content = std::fs::read_to_string(&scratch)
        .with_context(|| format!("can't read back {}", scratch.display()))?;
    Ok((content, opened))
}

/// Reformats one doc, or every doc when `path` is `None`, running each through
/// rumdl. With `check` set it writes nothing and instead exits non-zero when
/// any doc would change, for use in a pre-commit hook or CI.
fn format(store: &DocStore, path: Option<&str>, check: bool) -> Result<()> {
    let paths: Vec<String> = match path {
        Some(path) => {
            if !store.list_pages()?.iter().any(|page| page.path == path) {
                return Err(StoreError::NotFound(path.to_string()).into());
            }
            vec![path.to_string()]
        },
        // Only markdown docs; a stored `rumdl.toml` or the like is not markdown
        // and rumdl would mangle it.
        None => store
            .list_pages()?
            .into_iter()
            .map(|page| page.path)
            .filter(|path| path.ends_with(".md"))
            .collect(),
    };

    let mut changed = 0;
    for path in paths {
        let original = store.read(path.clone())?;
        let formatted = store.reformat(original.clone())?;
        if formatted == original {
            continue;
        }
        changed += 1;
        if check {
            println!("{}", cformat!("<yellow>would reformat</> {path}"));
        } else {
            store.write(path.clone(), formatted, None)?;
            println!("{}", cformat!("<green>reformatted</> {path}"));
        }
    }

    match (changed, check) {
        (0, _) => println!("already formatted"),
        (n, true) => bail!("{n} doc(s) need formatting"),
        _ => {},
    }
    Ok(())
}

fn replace(
    store: &DocStore,
    path: &str,
    old: &str,
    new: &str,
    all: bool,
    message: Option<String>,
) -> Result<()> {
    let count = store.replace(path, old, new, all, message)?;
    let noun = if count == 1 {
        "occurrence"
    } else {
        "occurrences"
    };
    println!("replaced {count} {noun} in {path}");
    Ok(())
}

fn rename(store: &DocStore, from: &str, to: &str, message: Option<String>) -> Result<()> {
    for (source, dest) in store.rename(from, to, message)? {
        println!("moved {source} -> {dest}");
    }
    Ok(())
}

fn remove(store: &DocStore, path: &str, message: Option<String>) -> Result<()> {
    store.delete_with_message(path, message)?;
    println!("deleted {path}");
    Ok(())
}

/// Dumps every page to a directory (a fresh tmpdir by default), preserving each
/// page's path. Meant to pair with `rd edit`: export, edit the files with
/// ordinary tools, then write each changed one back.
fn export(store: &DocStore, dir: Option<PathBuf>) -> Result<()> {
    let root = match dir {
        Some(dir) => {
            std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
            dir
        },
        // Kept, not cleaned up on drop, so the caller can edit the files in it.
        None => tempfile::Builder::new()
            .prefix("rd-export-")
            .tempdir()?
            .keep(),
    };

    for page in store.list_pages()? {
        let file = root.join(&page.path);
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&file, store.read(page.path)?)?;
    }

    println!("{}", root.display());
    Ok(())
}

fn open_page(store: &DocStore, root: &Path, path: &str) -> Result<()> {
    if path == "." {
        return open::repo(root);
    }
    let pages = store.list_pages()?;
    if !pages.iter().any(|page| page.path == path) {
        return Err(StoreError::NotFound(path.to_string()).into());
    }
    open::repo(root)
}

/// Symlinks `~/.local/bin/rd` at this binary, the copy inside
/// `RepoDocs.app/Contents/MacOS` when `rd` ships with the app.
fn install() -> Result<()> {
    let target = std::env::current_exe()
        .context("determining rd's own path")?
        .canonicalize()
        .context("resolving rd's own path")?;

    let home = std::env::var("HOME").context("HOME is not set")?;
    let link = PathBuf::from(home).join(".local/bin/rd");
    let bin = link.parent().expect("link always has a parent");
    std::fs::create_dir_all(bin).with_context(|| format!("couldn't create {}", bin.display()))?;

    // symlink_metadata, not exists: a link pointing at a deleted target still
    // occupies the name and still has to go.
    if std::fs::symlink_metadata(&link).is_ok() {
        std::fs::remove_file(&link)?;
    }
    std::os::unix::fs::symlink(&target, &link)?;

    let link = link.display();
    println!("{}", cformat!("Installed <bold>rd</> to {link}"));
    std::io::stdout().flush()?;
    Ok(())
}
