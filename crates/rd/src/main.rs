//! `rd`: read and write a repository's docs from a terminal.
//!
//! Every storage operation goes through `rd_core`, the same crate the RepoDocs
//! app links through UniFFI, so the CLI and the GUI stay in sync.

mod agent;
mod markdown;
mod open;
mod relative;

use std::io::{IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use clml::{ceprintln, cformat};
use rd_core::{DocStore, Git};

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
    },
    /// Print a doc's content
    Cat { path: String },
    /// Edit a doc: $EDITOR if no file, '-' for stdin, or from a file
    Edit {
        path: String,
        /// A file to read the new content from, or '-' for stdin
        file: Option<String>,
    },
    /// Delete a doc
    #[command(alias = "delete")]
    Rm { path: String },
    /// Reformat a doc, or every doc, with rumdl
    Fmt {
        /// A doc to format; omit to format every doc
        path: Option<String>,
        /// Report which docs would change without writing them
        #[arg(long)]
        check: bool,
    },
    /// Dump every doc to a directory (default: a fresh tmpdir)
    Export { dir: Option<PathBuf> },
    /// Open a doc, or '.' for the current repo, in the RepoDocs app
    Open { path: String },
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

    match cli.command {
        None => list(&store, false),
        Some(Cmd::List { by_date }) => list(&store, by_date),
        Some(Cmd::Cat { path }) => cat(&store, &path),
        Some(Cmd::Edit { path, file }) => edit(&store, &path, file.as_deref()),
        Some(Cmd::Rm { path }) => remove(&store, &path),
        Some(Cmd::Fmt { path, check }) => format(&store, path.as_deref(), check),
        Some(Cmd::Export { dir }) => export(&store, dir),
        Some(Cmd::Open { path }) => open_page(&store, &root, &path),
        Some(Cmd::Shorthand(args)) => {
            let path = &args[0];
            if path == "." {
                open::repo(&root)
            } else {
                cat(&store, path)
            }
        },
        Some(Cmd::Agent | Cmd::Install) => unreachable!("handled above"),
    }
}

fn list(store: &DocStore, by_date: bool) -> Result<()> {
    let pages = store.list_pages()?;
    if pages.is_empty() {
        println!("No pages yet");
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

fn cat(store: &DocStore, path: &str) -> Result<()> {
    let content = store.read(path.to_string())?;
    // `print!`, not `println!`: pages end in their own newline, and the tty
    // branch shouldn't add a blank line the piped branch doesn't.
    if std::io::stdout().is_terminal() {
        print!("{}", markdown::colorize(&content));
    } else {
        print!("{content}");
    }
    Ok(())
}

/// Writes a page from `file`, from stdin when `file` is `-`, or by opening
/// `$EDITOR` on the page's current content when no file is given. Creates the
/// page if it doesn't exist yet, same as `DocStore::write`. There is no
/// separate "new" command.
fn edit(store: &DocStore, path: &str, file: Option<&str>) -> Result<()> {
    let content = match file {
        Some("-") => {
            let mut buffer = String::new();
            std::io::stdin()
                .read_to_string(&mut buffer)
                .context("reading stdin")?;
            buffer
        },
        Some(file) => {
            std::fs::read_to_string(file).with_context(|| format!("can't read {file}"))?
        },
        None => edit_interactively(store, path)?,
    };
    store.write(path.to_string(), content, None)?;
    println!("wrote {path}");
    Ok(())
}

/// Opens `$EDITOR` (falling back to `vi`) on a scratch file seeded with the
/// page's current content, if any, and returns what the editor left behind.
fn edit_interactively(store: &DocStore, path: &str) -> Result<String> {
    let editor = std::env::var("EDITOR").unwrap_or_else(|_| "vi".to_string());
    let existing = store.read(path.to_string()).unwrap_or_default();

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

    std::fs::read_to_string(&scratch)
        .with_context(|| format!("can't read back {}", scratch.display()))
}

/// Reformats one doc, or every doc when `path` is `None`, running each through
/// rumdl. With `check` set it writes nothing and instead exits non-zero when
/// any doc would change, for use in a pre-commit hook or CI.
fn format(store: &DocStore, path: Option<&str>, check: bool) -> Result<()> {
    let paths: Vec<String> = match path {
        Some(path) => {
            if !store.list_pages()?.iter().any(|page| page.path == path) {
                bail!("no such page: {path}");
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

fn remove(store: &DocStore, path: &str) -> Result<()> {
    store.delete(path.to_string())?;
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
        bail!("no such page: {path}");
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
