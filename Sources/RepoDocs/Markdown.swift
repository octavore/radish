import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

/// Colorizes markdown source for terminal display (`rd cat`), using the same
/// tree-sitter grammar `CharmingEditor` uses to highlight the doc in the GUI —
/// a real parse rather than a regex approximation, so nesting, code fences,
/// and links are handled the way the editor itself understands them.
///
/// tree-sitter-markdown is a "split" grammar: the block parser leaves each
/// paragraph's content as an unparsed `inline` node, which is re-parsed with
/// the inline grammar to find emphasis, code spans, and links within it.
enum Markdown {
  private static let reset = "\u{1B}[0m"
  private static let bold = "\u{1B}[1m"
  private static let dim = "\u{1B}[2m"
  private static let italic = "\u{1B}[3m"
  private static let underline = "\u{1B}[4m"
  private static let strike = "\u{1B}[9m"
  private static let cyan = "\u{1B}[36m"
  private static let yellow = "\u{1B}[33m"
  private static let green = "\u{1B}[32m"

  /// Returns `source` unchanged if the grammar fails to load or parse — a
  /// `cat` should never fail or garble content just because coloring didn't
  /// work out.
  static func colorize(_ source: String) -> String {
    guard let root = parseBlocks(source) else { return source }
    let ns = source as NSString
    var spans: [Span] = []
    walkBlock(root, source: ns, into: &spans)
    return render(source: ns, spans: spans)
  }

  private struct Span {
    let range: NSRange
    let codes: [String]
  }

  private static func parseBlocks(_ source: String) -> Node? {
    let parser = Parser()
    let language = Language(tree_sitter_markdown())
    guard (try? parser.setLanguage(language)) != nil else { return nil }
    guard let tree = parser.parse(source) else { return nil }
    return tree.rootNode
  }

  private static func parseInline(_ text: String) -> Node? {
    let parser = Parser()
    let language = Language(tree_sitter_markdown_inline())
    guard (try? parser.setLanguage(language)) != nil else { return nil }
    guard let tree = parser.parse(text) else { return nil }
    return tree.rootNode
  }

  /// UTF-16 `NSRange` for a tree-sitter node's byte range, which is UTF-16LE
  /// (two bytes per code unit), optionally shifted by `base` for a node
  /// re-parsed from a substring whose own offsets restart at zero.
  private static func nsRange(_ node: Node, base: Int = 0) -> NSRange {
    NSRange(
      location: Int(node.byteRange.lowerBound) / 2 + base,
      length: Int(node.byteRange.upperBound - node.byteRange.lowerBound) / 2)
  }

  private static func walkBlock(_ node: Node, source: NSString, into spans: inout [Span]) {
    switch node.nodeType ?? "" {
    case "atx_heading", "setext_heading":
      spans.append(Span(range: nsRange(node), codes: [bold, cyan]))
      return  // headings carry no separate inline markup worth descending for
    case "fenced_code_block", "indented_code_block":
      spans.append(Span(range: nsRange(node), codes: [green]))
      return  // code is verbatim
    case "block_quote":
      spans.append(Span(range: nsRange(node), codes: [dim, italic]))
    case "inline":
      styleInline(node, source: source, into: &spans)
      return
    default:
      break
    }
    for index in 0..<node.childCount {
      if let child = node.child(at: index) {
        walkBlock(child, source: source, into: &spans)
      }
    }
  }

  private static func styleInline(_ inlineNode: Node, source: NSString, into spans: inout [Span]) {
    let range = nsRange(inlineNode)
    guard range.length > 0, range.location + range.length <= source.length else { return }
    let text = source.substring(with: range)
    guard let root = parseInline(text) else { return }
    walkInline(root, base: range.location, into: &spans)
  }

  private static func walkInline(_ node: Node, base: Int, into spans: inout [Span]) {
    switch node.nodeType ?? "" {
    case "emphasis":
      spans.append(Span(range: nsRange(node, base: base), codes: [italic]))
    case "strong_emphasis":
      spans.append(Span(range: nsRange(node, base: base), codes: [bold]))
    case "code_span":
      spans.append(Span(range: nsRange(node, base: base), codes: [yellow]))
    case "strikethrough":
      spans.append(Span(range: nsRange(node, base: base), codes: [strike]))
    case "link_text", "image_description":
      spans.append(Span(range: nsRange(node, base: base), codes: [underline]))
    case "link_destination", "link_title", "uri_autolink":
      spans.append(Span(range: nsRange(node, base: base), codes: [dim]))
    default:
      break
    }
    for index in 0..<node.childCount {
      if let child = node.child(at: index) {
        walkInline(child, base: base, into: &spans)
      }
    }
  }

  /// Slices the text at every span boundary and, for each slice, resets and
  /// re-applies the codes of every span covering it — simpler than tracking
  /// opens/closes incrementally, and correct even when spans nest (a `code
  /// span` inside a heading) since each slice's styling is recomputed from
  /// scratch rather than layered onto whatever came before.
  private static func render(source: NSString, spans: [Span]) -> String {
    let length = source.length
    guard !spans.isEmpty, length > 0 else { return source as String }

    var boundaries: Set<Int> = [0, length]
    for span in spans where span.range.length > 0 {
      boundaries.insert(span.range.location)
      boundaries.insert(span.range.location + span.range.length)
    }
    let cuts = boundaries.sorted()

    var result = ""
    for i in 0..<(cuts.count - 1) {
      let start = cuts[i]
      let end = cuts[i + 1]
      let codes = spans
        .filter { $0.range.location <= start && start < $0.range.location + $0.range.length }
        .flatMap(\.codes)
      let slice = source.substring(with: NSRange(location: start, length: end - start))
      result += codes.isEmpty ? slice : codes.joined() + slice + reset
    }
    return result
  }
}
