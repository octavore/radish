import Foundation

enum GitError: Error, LocalizedError {
  case failed(args: [String], status: Int32, stderr: String)
  case notARepository(URL)

  var errorDescription: String? {
    switch self {
    case let .failed(args, status, stderr):
      let detail = stderr.isEmpty ? "no output" : stderr
      return "git \(args.joined(separator: " ")) failed (\(status)): \(detail)"
    case let .notARepository(url):
      return "\(url.path) is not a git repository"
    }
  }
}

/// A thin wrapper over `git` plumbing for a single repository.
///
/// Nothing here may touch the user's working tree, index, or HEAD — the app
/// runs against repos people are actively working in, so a stray checkout or
/// index write would be worse than the feature is worth. Writes route through a
/// temporary index via `GIT_INDEX_FILE`; merges go through `merge-tree`, which
/// needs no index at all.
struct Git: Sendable {
  let root: URL

  struct Output: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String

    var text: String {
      String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  /// Runs git and returns raw stdout. Throws on any nonzero exit.
  @discardableResult
  func run(_ args: [String], stdin: Data? = nil, env: [String: String] = [:]) throws -> Data {
    let result = try capture(args, stdin: stdin, env: env)
    guard result.status == 0 else {
      throw GitError.failed(args: args, status: result.status, stderr: result.stderr)
    }
    return result.stdout
  }

  /// Runs git and returns the exit status alongside its output, without throwing.
  ///
  /// Needed for commands where a nonzero exit is a *result*, not an error —
  /// `merge-tree` exits 1 on a conflict but still prints the tree and the
  /// conflicted stages we need.
  func capture(_ args: [String], stdin: Data? = nil, env: [String: String] = [:]) throws -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + args

    var environment = ProcessInfo.processInfo.environment
    environment.merge(env) { _, new in new }
    process.environment = environment

    let output = Pipe()
    let errors = Pipe()
    let input = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = input

    try process.run()

    // Feed stdin off-thread: a blob larger than the pipe buffer would otherwise
    // wedge us, since nobody is draining stdout while we write.
    if let stdin {
      DispatchQueue.global().async {
        input.fileHandleForWriting.write(stdin)
        try? input.fileHandleForWriting.close()
      }
    } else {
      try? input.fileHandleForWriting.close()
    }

    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return Output(
      status: process.terminationStatus,
      stdout: stdout,
      stderr: String(decoding: stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Runs git and returns trimmed stdout as text.
  func text(_ args: [String], stdin: Data? = nil, env: [String: String] = [:]) throws -> String {
    String(decoding: try run(args, stdin: stdin, env: env), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Runs git in a temporary index so the repository's real index is untouched.
  func withTemporaryIndex<T>(_ body: (_ env: [String: String]) throws -> T) rethrows -> T {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("repo-docs-index-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    return try body(["GIT_INDEX_FILE": path])
  }

  /// The OID a ref points at, or nil when the ref does not exist yet.
  func resolve(_ ref: String) -> String? {
    try? text(["rev-parse", "--verify", "--quiet", ref])
  }

  static func isRepository(_ url: URL) -> Bool {
    let git = Git(root: url)
    return (try? git.text(["rev-parse", "--git-dir"])) != nil
  }
}
