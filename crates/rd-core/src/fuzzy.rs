//! Fuzzy path matching for the app's Go to Page palette.

use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};

use crate::types::FuzzyMatch;

/// Paths matching `query`, best first, at most `limit` of them.
///
/// Scoring is nucleo's (fzf-style) over the whole path, plus the score of the
/// file name alone when the query also matches there, so `auth` ranks
/// `design/auth.md` above `auth/tokens/refresh.md`. Ties keep the order of
/// `paths`, so a caller that passes paths newest first gets recent pages first.
/// An empty query matches every path with no highlighted characters.
///
/// Case is smart: an all-lowercase query ignores case, and any uppercase
/// character makes the match case-sensitive. Whitespace separates terms, and
/// every term must match.
#[uniffi::export]
pub fn fuzzy_match(query: String, paths: Vec<String>, limit: u32) -> Vec<FuzzyMatch> {
    let pattern = Pattern::parse(&query, CaseMatching::Smart, Normalization::Smart);
    let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
    let mut buf = Vec::new();

    let mut matches: Vec<FuzzyMatch> = paths
        .into_iter()
        .filter_map(|path| {
            let mut indices = Vec::new();
            let full =
                pattern.indices(Utf32Str::new(&path, &mut buf), &mut matcher, &mut indices)?;
            let name = path.rsplit('/').next().unwrap_or(&path);
            let name_score = pattern
                .score(Utf32Str::new(name, &mut buf), &mut matcher)
                .unwrap_or(0);
            // Indices from multiple terms arrive unsorted and may repeat.
            indices.sort_unstable();
            indices.dedup();
            Some(FuzzyMatch {
                score: full + name_score,
                indices,
                path,
            })
        })
        .collect();
    // Stable, so equal scores keep the caller's order.
    matches.sort_by(|a, b| b.score.cmp(&a.score));
    matches.truncate(limit as usize);
    matches
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths() -> Vec<String> {
        [
            "auth/tokens/refresh.md",
            "design/auth.md",
            "docs/ARCHITECTURE.md",
            "docs/STORAGE.md",
            "plans/20260715-2116-runnable-snippets.md",
        ]
        .map(String::from)
        .to_vec()
    }

    fn ranked(query: &str) -> Vec<String> {
        fuzzy_match(query.to_string(), paths(), 10)
            .into_iter()
            .map(|found| found.path)
            .collect()
    }

    #[test]
    fn empty_query_keeps_input_order() {
        assert_eq!(ranked(""), paths());
    }

    #[test]
    fn subsequence() {
        assert_eq!(ranked("strg"), ["docs/STORAGE.md"]);
    }

    #[test]
    fn file_name_outranks_folder() {
        assert_eq!(ranked("auth")[0], "design/auth.md");
    }

    #[test]
    fn terms_must_all_match() {
        assert_eq!(ranked("docs arch"), ["docs/ARCHITECTURE.md"]);
    }

    #[test]
    fn uppercase_is_case_sensitive() {
        assert!(ranked("storage").contains(&"docs/STORAGE.md".to_string()));
        assert!(ranked("Storage").is_empty());
    }

    #[test]
    fn no_match() {
        assert!(ranked("zzq").is_empty());
    }

    #[test]
    fn limit() {
        assert_eq!(fuzzy_match(String::new(), paths(), 2).len(), 2);
    }

    #[test]
    fn indices_are_sorted_char_offsets() {
        let found = fuzzy_match("arch docs".to_string(), paths(), 10);
        assert_eq!(found[0].indices, [0, 1, 2, 3, 5, 6, 7, 8]);
    }
}
