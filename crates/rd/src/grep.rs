//! `rd grep`: search doc content with a regex. Docs are read from the store,
//! never from disk.

use std::io::{BufWriter, IsTerminal, Write};

use anyhow::{Context, Result};
use clap::Args;
use clml::cformat;
use rd_core::DocStore;
use regex::{Regex, RegexBuilder};

#[derive(Args)]
pub struct GrepArgs {
    /// The regex to search for (a literal string with -F)
    pattern: String,
    /// Only search docs at these paths or under these folders
    paths: Vec<String>,
    /// Match case-insensitively
    #[arg(short = 'i', long)]
    ignore_case: bool,
    /// Match case-insensitively unless the pattern has an uppercase letter
    #[arg(short = 'S', long, conflicts_with = "ignore_case")]
    smart_case: bool,
    /// Treat the pattern as a literal string
    #[arg(short = 'F', long)]
    fixed_strings: bool,
    /// Only match whole words
    #[arg(short = 'w', long)]
    word_regexp: bool,
    /// Select lines that do not match
    #[arg(short = 'v', long)]
    invert_match: bool,
    /// Print only the paths of docs that have a match
    #[arg(short = 'l', long, conflicts_with_all = ["files_without_match", "count"])]
    files_with_matches: bool,
    /// Print only the paths of docs that have no match
    #[arg(short = 'L', long, conflicts_with = "count")]
    files_without_match: bool,
    /// Print the number of matching lines per doc
    #[arg(short = 'c', long)]
    count: bool,
    /// Print only the matched parts of a line
    #[arg(short = 'o', long)]
    only_matching: bool,
    /// Show line numbers (the default; accepted so -n works as in grep)
    #[arg(short = 'n', long, conflicts_with = "no_line_number")]
    line_number: bool,
    /// Omit line numbers
    #[arg(short = 'N', long)]
    no_line_number: bool,
    /// Stop after this many matching lines per doc
    #[arg(short = 'm', long, value_name = "NUM")]
    max_count: Option<usize>,
    /// Show NUM lines after each match
    #[arg(short = 'A', long, value_name = "NUM")]
    after_context: Option<usize>,
    /// Show NUM lines before each match
    #[arg(short = 'B', long, value_name = "NUM")]
    before_context: Option<usize>,
    /// Show NUM lines before and after each match
    #[arg(short = 'C', long, value_name = "NUM")]
    context: Option<usize>,
}

/// Runs the search and returns whether any doc matched, so the caller can
/// exit 1 on no match, as grep does.
pub fn run(store: &DocStore, args: &GrepArgs) -> Result<bool> {
    let regex = build_regex(args)?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    match search(store, args, &regex, &mut out) {
        // A closed pipe (`rd grep x | head`) is a normal way to stop.
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::BrokenPipe) =>
        {
            Ok(true)
        },
        result => {
            out.flush().ok();
            result
        },
    }
}

fn build_regex(args: &GrepArgs) -> Result<Regex> {
    let mut pattern = if args.fixed_strings {
        regex::escape(&args.pattern)
    } else {
        args.pattern.clone()
    };
    if args.word_regexp {
        pattern = format!(r"\b(?:{pattern})\b");
    }
    let smart_insensitive = args.smart_case && !args.pattern.chars().any(char::is_uppercase);
    RegexBuilder::new(&pattern)
        .case_insensitive(args.ignore_case || smart_insensitive)
        .build()
        .context("invalid pattern")
}

fn search(store: &DocStore, args: &GrepArgs, regex: &Regex, out: &mut impl Write) -> Result<bool> {
    let color = std::io::stdout().is_terminal();
    let before = args.before_context.or(args.context).unwrap_or(0);
    let after = args.after_context.or(args.context).unwrap_or(0);
    let show_context = (before > 0 || after > 0) && !args.only_matching;

    let mut pages: Vec<String> = store
        .list_pages()?
        .into_iter()
        .map(|page| page.path)
        .filter(|path| in_scope(path, &args.paths))
        .collect();
    pages.sort();

    let mut any_match = false;
    let mut printed_lines = false;
    for path in pages {
        let content = store.read(path.clone())?;
        let lines: Vec<&str> = content.lines().collect();

        let mut matched: Vec<bool> = lines
            .iter()
            .map(|line| regex.is_match(line) != args.invert_match)
            .collect();
        if let Some(max) = args.max_count {
            let mut seen = 0;
            for hit in matched.iter_mut().filter(|hit| **hit) {
                seen += 1;
                if seen > max {
                    *hit = false;
                }
            }
        }
        let count = matched.iter().filter(|hit| **hit).count();
        any_match |= count > 0;

        if args.files_with_matches {
            if count > 0 {
                writeln!(out, "{}", styled_path(&path, color))?;
            }
            continue;
        }
        if args.files_without_match {
            if count == 0 {
                writeln!(out, "{}", styled_path(&path, color))?;
            }
            continue;
        }
        if args.count {
            if count > 0 {
                writeln!(out, "{}:{count}", styled_path(&path, color))?;
            }
            continue;
        }
        if count == 0 {
            continue;
        }

        let mut visible = vec![false; lines.len()];
        for (index, _) in matched.iter().enumerate().filter(|(_, hit)| **hit) {
            let start = index.saturating_sub(before);
            let end = (index + after).min(lines.len() - 1);
            visible[start..=end].fill(true);
        }

        let mut last_printed: Option<usize> = None;
        for (index, line) in lines.iter().enumerate() {
            if !visible[index] {
                continue;
            }
            let is_match = matched[index];
            if show_context && printed_lines && last_printed.is_none_or(|last| last + 1 != index) {
                writeln!(out, "--")?;
            }
            last_printed = Some(index);
            printed_lines = true;

            let separator = if is_match { ':' } else { '-' };
            let mut prefix = styled_path(&path, color);
            prefix.push(separator);
            if !args.no_line_number {
                let number = index + 1;
                let number = if color {
                    cformat!("<green>{number}</>")
                } else {
                    number.to_string()
                };
                prefix.push_str(&number);
                prefix.push(separator);
            }

            if args.only_matching {
                if !args.invert_match {
                    for found in regex.find_iter(line).filter(|found| !found.is_empty()) {
                        writeln!(out, "{prefix}{}", highlight(found.as_str(), color))?;
                    }
                }
            } else if is_match && color && !args.invert_match {
                writeln!(out, "{prefix}{}", highlight_line(regex, line))?;
            } else {
                writeln!(out, "{prefix}{line}")?;
            }
        }
    }
    Ok(any_match)
}

/// A doc is in scope when no paths are given, or it equals a given path or
/// sits under it as a folder.
fn in_scope(path: &str, scopes: &[String]) -> bool {
    scopes.is_empty()
        || scopes.iter().any(|scope| {
            let scope = scope.trim_end_matches('/');
            path == scope
                || path
                    .strip_prefix(scope)
                    .is_some_and(|rest| rest.starts_with('/'))
        })
}

fn styled_path(path: &str, color: bool) -> String {
    if color {
        cformat!("<cyan>{path}</>")
    } else {
        path.to_string()
    }
}

fn highlight(text: &str, color: bool) -> String {
    if color {
        cformat!("<red>{text}</>")
    } else {
        text.to_string()
    }
}

fn highlight_line(regex: &Regex, line: &str) -> String {
    let mut result = String::new();
    let mut last = 0;
    for found in regex.find_iter(line).filter(|found| !found.is_empty()) {
        result.push_str(&line[last..found.start()]);
        result.push_str(&highlight(found.as_str(), true));
        last = found.end();
    }
    result.push_str(&line[last..]);
    result
}
