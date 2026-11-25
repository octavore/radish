use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::error::{Result, StoreError};

/// Git executable. macOS uses the system git. Other platforms resolve it from
/// PATH.
#[cfg(target_os = "macos")]
const GIT: &str = "/usr/bin/git";
#[cfg(not(target_os = "macos"))]
const GIT: &str = "git";

/// Raw result of one git invocation.
pub struct Output {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: String,
}

/// A thin wrapper over `git` plumbing for a single repository.
///
/// Nothing here may touch the user's working tree, index, or HEAD: the app
/// runs against repos people are actively working in, where a stray checkout
/// or index write would lose their work. Writes route through a temporary
/// index via `GIT_INDEX_FILE`; merges go through `merge-tree`, which needs no
/// index at all.
#[derive(Debug, Clone)]
pub struct Git {
    pub root: PathBuf,
}

impl Git {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Runs git and returns raw stdout. Errors on any nonzero exit.
    pub fn run(&self, args: &[&str]) -> Result<Vec<u8>> {
        self.run_with(args, None, &HashMap::new())
    }

    pub fn run_with(
        &self,
        args: &[&str],
        stdin: Option<&[u8]>,
        env: &HashMap<String, String>,
    ) -> Result<Vec<u8>> {
        let output = self.capture(args, stdin, env)?;
        if output.status != 0 {
            let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
            return Err(StoreError::git(&args, output.status, &output.stderr));
        }
        Ok(output.stdout)
    }

    /// Runs git and returns the exit status alongside its output, without
    /// erroring.
    ///
    /// Needed for commands where a nonzero exit is a *result*, not an error.
    /// `merge-tree` exits 1 on a conflict but still prints the tree and the
    /// conflicted stages we need.
    pub fn capture(
        &self,
        args: &[&str],
        stdin: Option<&[u8]>,
        env: &HashMap<String, String>,
    ) -> Result<Output> {
        let mut command = Command::new(GIT);
        command
            // Path-listing commands (`ls-tree`, `log --name-only`) otherwise
            // C-quote any path with a non-ASCII byte: `notes/café.md` comes
            // back as `"notes/caf\303\251.md"`, which no later `cat-file` can
            // resolve. Off globally so no call site can forget it.
            .args(["-c", "core.quotePath=false"])
            .arg("-C")
            .arg(&self.root)
            .args(args)
            .envs(env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let mut child = command
            .spawn()
            .map_err(|error| StoreError::Spawn(error.to_string()))?;

        // Feed stdin off-thread: a blob larger than the pipe buffer would
        // otherwise deadlock, since nobody is draining stdout while we write.
        let writer = child.stdin.take().map(|mut pipe| {
            let payload = stdin.unwrap_or_default().to_vec();
            std::thread::spawn(move || {
                let _ = pipe.write_all(&payload);
            })
        });

        let output = child.wait_with_output()?;
        if let Some(writer) = writer {
            let _ = writer.join();
        }

        Ok(Output {
            status: output.status.code().unwrap_or(-1),
            stdout: output.stdout,
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
        })
    }

    /// Runs git and returns trimmed stdout as text.
    pub fn text(&self, args: &[&str]) -> Result<String> {
        Ok(String::from_utf8_lossy(&self.run(args)?).trim().to_string())
    }

    pub fn text_with(
        &self,
        args: &[&str],
        stdin: Option<&[u8]>,
        env: &HashMap<String, String>,
    ) -> Result<String> {
        Ok(String::from_utf8_lossy(&self.run_with(args, stdin, env)?)
            .trim()
            .to_string())
    }

    /// Runs git in a temporary index so the repository's real index is
    /// untouched. The file is removed when `guard` drops, including on an
    /// early `?` return from `body`.
    pub fn with_temporary_index<T>(
        &self,
        body: impl FnOnce(&HashMap<String, String>) -> Result<T>,
    ) -> Result<T> {
        // A path, not a created file: `git read-tree`/`update-index` want to
        // create the index themselves, and an existing empty file reads as a
        // corrupt index.
        let guard = TempIndex::new()?;
        let env = HashMap::from([(
            "GIT_INDEX_FILE".to_string(),
            guard.path.display().to_string(),
        )]);
        body(&env)
    }

    /// The OID a ref points at, or `None` when the ref does not exist yet.
    pub fn resolve(&self, reference: &str) -> Option<String> {
        self.text(&["rev-parse", "--verify", "--quiet", reference])
            .ok()
            .filter(|oid| !oid.is_empty())
    }

    pub fn is_repository(path: &Path) -> bool {
        Git::new(path).text(&["rev-parse", "--git-dir"]).is_ok()
    }

    /// The repository root containing `path`, or `None` when it isn't in one.
    pub fn discover(path: &Path) -> Option<PathBuf> {
        Git::new(path)
            .text(&["rev-parse", "--show-toplevel"])
            .ok()
            .filter(|top| !top.is_empty())
            .map(PathBuf::from)
    }
}

/// A never-created temp path, deleted on drop.
struct TempIndex {
    path: PathBuf,
}

impl TempIndex {
    fn new() -> Result<Self> {
        let file = tempfile::Builder::new()
            .prefix("radish-index-")
            .tempfile()?;
        // Keep the unique name, drop the file itself: git wants to create it.
        let (_, path) = file
            .keep()
            .map_err(|error| StoreError::Io(error.to_string()))?;
        std::fs::remove_file(&path)?;
        Ok(Self { path })
    }
}

impl Drop for TempIndex {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
