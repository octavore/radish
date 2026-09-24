//! "Did you mean" suggestions for a doc path that doesn't exist.

/// Up to three existing paths close to `missing`, best first. A path counts as
/// close when it differs only in case, shares the file name, contains
/// `missing`, or is within a small edit distance of it.
pub fn close_matches(missing: &str, paths: &[String]) -> Vec<String> {
    let wanted = missing.trim_end_matches('/').to_lowercase();
    let wanted_name = file_name(&wanted);
    let limit = (wanted.chars().count() / 3).max(2);

    let mut scored: Vec<(usize, usize, &String)> = paths
        .iter()
        .filter_map(|path| {
            let candidate = path.to_lowercase();
            let distance = edit_distance(&wanted, &candidate);
            let rank = if candidate == wanted {
                0
            } else if file_name(&candidate) == wanted_name {
                1
            } else if candidate.contains(&wanted) {
                2
            } else if distance <= limit {
                3
            } else {
                return None;
            };
            Some((rank, distance, path))
        })
        .collect();
    scored.sort();
    scored
        .into_iter()
        .take(3)
        .map(|(_, _, path)| path.clone())
        .collect()
}

fn file_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Levenshtein distance over chars.
fn edit_distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, a_char) in a.chars().enumerate() {
        let mut diagonal = row[0];
        row[0] = i + 1;
        for (j, b_char) in b.iter().enumerate() {
            let above = row[j + 1];
            let cost = usize::from(a_char != *b_char);
            row[j + 1] = (above + 1).min(row[j] + 1).min(diagonal + cost);
            diagonal = above;
        }
    }
    row[b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths() -> Vec<String> {
        [
            "docs/ARCHITECTURE.md",
            "docs/STORAGE.md",
            "plans/20260715-2116-runnable-snippets.md",
        ]
        .map(String::from)
        .to_vec()
    }

    #[test]
    fn case_only_difference() {
        assert_eq!(
            close_matches("docs/architecture.md", &paths()),
            ["docs/ARCHITECTURE.md"]
        );
    }

    #[test]
    fn missing_folder_prefix() {
        assert_eq!(close_matches("STORAGE.md", &paths()), ["docs/STORAGE.md"]);
    }

    #[test]
    fn typo() {
        assert_eq!(
            close_matches("docs/STORGE.md", &paths()),
            ["docs/STORAGE.md"]
        );
    }

    #[test]
    fn substring() {
        assert_eq!(
            close_matches("runnable", &paths()),
            ["plans/20260715-2116-runnable-snippets.md"]
        );
    }

    #[test]
    fn nothing_close() {
        assert!(close_matches("zzz/qqq.txt", &paths()).is_empty());
    }
}
