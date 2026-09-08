//! Markdown reformatting, backed by rumdl.
//!
//! `reformat` runs rumdl's autofixable rules over a doc's source and hands back
//! the rewritten text. Config resolution lives in `DocStore::reformat`, which
//! calls this; see that method for the precedence rules.

use std::io::Write;
use std::path::Path;

use rumdl_lib::config::{default_registry, Config, SourcedConfig};
use rumdl_lib::document_run::DocumentRun;
use rumdl_lib::{all_rules, filter_rules};

/// Applies rumdl's fixes to `content` and returns the result.
///
/// `config_doc` is the text of a rumdl config stored as a doc, when the repo
/// has one; `repo_root` is where working-tree config discovery starts. rumdl
/// stops after ten fix passes, the same ceiling its own CLI uses, and leaves
/// the text untouched on an internal error, so this returns `content` unchanged
/// rather than failing.
pub fn reformat(content: &str, config_doc: Option<&str>, repo_root: &Path) -> String {
    let config = resolve_config(config_doc, repo_root);
    let rules = filter_rules(&all_rules(&config), &config.global);
    let run = DocumentRun::new(content, &rules, &config);
    match run.fix(10) {
        Ok((fixed, _)) => fixed,
        Err(_) => content.to_string(),
    }
}

/// Picks one config source, the way rumdl does, with a doc-stored config as an
/// extra tier on top: a config held as a doc wins over anything in the working
/// tree, which in turn wins over the user-level config. rumdl never merges
/// these tiers; the first one that resolves is the whole config. Any failure
/// along the way falls through to rumdl's built-in defaults.
fn resolve_config(config_doc: Option<&str>, repo_root: &Path) -> Config {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    let user_config_dir = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| home.as_ref().map(|home| home.join(".config")));

    let sourced = match config_doc {
        // rumdl parses config only from a file, so stage the doc in a scratch
        // file and hand rumdl that. The scratch file is a tempdir write, never
        // the repo working tree.
        Some(toml) => stage(toml).and_then(|file| {
            SourcedConfig::load_discovered(file.path(), user_config_dir.as_deref(), home.as_deref())
                .ok()
        }),
        None => SourcedConfig::load_for_workspace(
            repo_root,
            None,
            user_config_dir.as_deref(),
            home.as_deref(),
        )
        .ok(),
    };

    sourced
        .and_then(|sourced| sourced.validate_into(default_registry()).ok())
        .map(|(config, _warnings)| config)
        .unwrap_or_default()
}

/// Writes `toml` to a scratch `.toml` file for rumdl to read back.
fn stage(toml: &str) -> Option<tempfile::NamedTempFile> {
    let mut file = tempfile::Builder::new()
        .prefix("rd-rumdl-")
        .suffix(".toml")
        .tempfile()
        .ok()?;
    file.write_all(toml.as_bytes()).ok()?;
    file.flush().ok()?;
    Some(file)
}
