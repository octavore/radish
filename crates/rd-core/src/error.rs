use std::path::Path;

use thiserror::Error;

/// Errors surfaced across the FFI boundary. UniFFI renders this as a Swift
/// `Error` whose `localizedDescription` is the `#[error]` string, which is what
/// the app's `errorMessage` alerts show.
#[derive(Debug, Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum StoreError {
    #[error("git {args} failed ({status}): {stderr}")]
    Git {
        args: String,
        status: i32,
        stderr: String,
    },

    #[error("could not run git: {0}")]
    Spawn(String),

    #[error("{0} is not a git repository")]
    NotARepository(String),

    #[error("{0}")]
    Io(String),

    #[error("{0} is not valid UTF-8")]
    NotUtf8(String),

    #[error("{path} changed since it was read (expected blob {expected}, found {actual})")]
    Stale {
        path: String,
        expected: String,
        actual: String,
    },
}

impl StoreError {
    pub(crate) fn git(args: &[String], status: i32, stderr: &str) -> Self {
        let stderr = if stderr.is_empty() {
            "no output".to_string()
        } else {
            stderr.to_string()
        };
        Self::Git {
            args: args.join(" "),
            status,
            stderr,
        }
    }

    pub(crate) fn not_a_repository(path: &Path) -> Self {
        Self::NotARepository(path.display().to_string())
    }
}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

pub type Result<T> = std::result::Result<T, StoreError>;
