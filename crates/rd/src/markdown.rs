//! Colorizes markdown source for terminal display (`rd cat`), using the same
//! tree-sitter grammar `CharmingEditor` uses to highlight the doc in the GUI —
//! a real parse rather than a regex approximation, so nesting, code fences, and
//! links are handled the way the editor itself understands them.
//!
//! tree-sitter-markdown is a "split" grammar: the block parser leaves each
//! paragraph's content as an unparsed `inline` node, which is re-parsed with
//! the inline grammar to find emphasis, code spans, and links within it.

use clml::cformat;
use tree_sitter::{Language, Node, Parser, Tree};

/// One styling primitive. Every ANSI sequence in `rd` comes from the `cformat!`
/// calls in `paint`, so the escape codes live in exactly one place.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Style {
    Bold,
    Cyan,
    Green,
    Yellow,
    Dim,
    Italic,
    Underline,
    Strike,
}

fn paint(style: Style, text: &str) -> String {
    match style {
        Style::Bold => cformat!("<bold>{text}</>"),
        Style::Cyan => cformat!("<cyan>{text}</>"),
        Style::Green => cformat!("<green>{text}</>"),
        Style::Yellow => cformat!("<yellow>{text}</>"),
        Style::Dim => cformat!("<dim>{text}</>"),
        Style::Italic => cformat!("<italics>{text}</>"),
        Style::Underline => cformat!("<underline>{text}</>"),
        Style::Strike => cformat!("<strike>{text}</>"),
    }
}

/// A byte range of the source and the styles covering it.
struct Span {
    start: usize,
    end: usize,
    styles: &'static [Style],
}

/// Returns `source` unchanged if the grammar fails to parse — a `cat` should
/// never fail or garble content just because coloring didn't work out.
pub fn colorize(source: &str) -> String {
    let Some(blocks) = parse(source, tree_sitter_md::LANGUAGE.into()) else {
        return source.to_string();
    };

    let mut spans = Vec::new();
    let mut inline_ranges = Vec::new();
    walk_block(blocks.root_node(), &mut spans, &mut inline_ranges);

    // The block grammar leaves each paragraph's content as one unparsed
    // `inline` node; re-parse each in isolation and shift its offsets back into
    // the document.
    for (start, end) in inline_ranges {
        let Some(text) = source.get(start..end) else {
            continue;
        };
        if let Some(inline) = parse(text, tree_sitter_md::INLINE_LANGUAGE.into()) {
            walk_inline(inline.root_node(), start, &mut spans);
        }
    }

    render(source, &spans)
}

fn parse(source: &str, language: Language) -> Option<Tree> {
    let mut parser = Parser::new();
    parser.set_language(&language).ok()?;
    parser.parse(source, None)
}

fn walk_block(node: Node, spans: &mut Vec<Span>, inline_ranges: &mut Vec<(usize, usize)>) {
    let span = |styles| Span {
        start: node.start_byte(),
        end: node.end_byte(),
        styles,
    };
    match node.kind() {
        "atx_heading" | "setext_heading" => {
            // Headings carry no separate inline markup worth descending for.
            spans.push(span(&[Style::Bold, Style::Cyan]));
            return;
        },
        "fenced_code_block" | "indented_code_block" => {
            spans.push(span(&[Style::Green])); // code is verbatim
            return;
        },
        "block_quote" => spans.push(span(&[Style::Dim, Style::Italic])),
        "inline" => {
            inline_ranges.push((node.start_byte(), node.end_byte()));
            return;
        },
        _ => {},
    }

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        walk_block(child, spans, inline_ranges);
    }
}

/// `base` shifts the subtree's offsets, which restart at zero because the
/// inline grammar parsed the paragraph's text in isolation.
fn walk_inline(node: Node, base: usize, spans: &mut Vec<Span>) {
    let styles: &'static [Style] = match node.kind() {
        "emphasis" => &[Style::Italic],
        "strong_emphasis" => &[Style::Bold],
        "code_span" => &[Style::Yellow],
        "strikethrough" => &[Style::Strike],
        "link_text" | "image_description" => &[Style::Underline],
        "link_destination" | "link_title" | "uri_autolink" => &[Style::Dim],
        _ => &[],
    };
    if !styles.is_empty() {
        spans.push(Span {
            start: node.start_byte() + base,
            end: node.end_byte() + base,
            styles,
        });
    }

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        walk_inline(child, base, spans);
    }
}

/// Slices the text at every span boundary and, for each slice, re-applies the
/// styles of every span covering it — simpler than tracking opens/closes
/// incrementally, and correct even when spans nest (a code span inside a
/// heading) since each slice's styling is recomputed from scratch rather than
/// layered onto whatever came before.
fn render(source: &str, spans: &[Span]) -> String {
    if spans.is_empty() || source.is_empty() {
        return source.to_string();
    }

    let mut cuts: Vec<usize> = vec![0, source.len()];
    for span in spans.iter().filter(|span| span.start < span.end) {
        cuts.push(span.start);
        cuts.push(span.end);
    }
    cuts.sort_unstable();
    cuts.dedup();

    let mut result = String::with_capacity(source.len());
    for pair in cuts.windows(2) {
        let (start, end) = (pair[0], pair[1]);
        let Some(slice) = source.get(start..end) else {
            // A boundary landing mid-codepoint would panic on slicing; skip
            // coloring rather than mangling the output.
            return source.to_string();
        };
        let styles = spans
            .iter()
            .filter(|span| span.start <= start && start < span.end)
            .flat_map(|span| span.styles);
        // Fold innermost-out: each wrap closes with a reset, and since the
        // whole slice is re-styled from scratch that renders correctly.
        result.push_str(&styles.fold(slice.to_string(), |text, style| paint(*style, &text)));
    }
    result
}
