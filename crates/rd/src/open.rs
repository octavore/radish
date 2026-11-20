//! Handing a repository to the RepoDocs app.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{anyhow, Context, Result};

/// Points the GUI app at `root` and brings it to the front, by delivering a
/// `repodocs://` URL naming it.
///
/// A plain `open <bundle>` on an already-running app just re-activates it
/// without telling it anything changed, since the app's model is built once per
/// process. The URL is what opens the repo. The app persists it as the
/// last-opened repo itself, so quitting and reopening from Finder resumes
/// there; the CLI writes no preferences.
///
/// A `page` is a doc path to select once the repo is open.
pub fn repo(root: &Path, page: Option<&str>) -> Result<()> {
    let app = bundle().ok_or_else(|| anyhow!("can't find RepoDocs.app to launch"))?;
    let mut url = format!(
        "repodocs://open?path={}",
        percent_encode(&root.to_string_lossy())
    );
    if let Some(page) = page {
        url.push_str("&page=");
        url.push_str(&percent_encode(page));
    }

    // `-a <bundle>` targets this exact app bundle directly, rather than relying
    // on `repodocs://` already being registered with LaunchServices (which can
    // lag right after a fresh local build).
    Command::new("/usr/bin/open")
        .arg("-a")
        .arg(&app)
        .arg(&url)
        .status()
        .with_context(|| format!("launching {}", app.display()))?;
    Ok(())
}

/// `rd` normally runs as a symlink at `~/.local/bin/rd`, so resolve the real
/// executable path and walk up to the enclosing `.app`.
fn bundle() -> Option<PathBuf> {
    let mut path = std::env::current_exe().ok()?.canonicalize().ok()?;
    while path.extension().is_none_or(|extension| extension != "app") {
        if !path.pop() {
            return None;
        }
    }
    Some(path)
}

/// Percent-encodes a path for a URL query value. Paths are the only thing that
/// goes through here, so the unreserved set plus `/` covers everything without
/// pulling in a URL crate for one function.
fn percent_encode(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                encoded.push(byte as char)
            },
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}
