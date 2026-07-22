import Darwin
import Foundation

/// The `rd` side of the executable (see `CLIInstaller`): list and print docs
/// from a terminal, against whatever repo the cwd is inside of. Reuses
/// `Git`/`DocStore` as-is since neither depends on AppKit or SwiftUI.
enum CLI {
  /// Launched from a terminal rather than Finder/`open`, stdout is a tty. If
  /// args were passed at all (e.g. invoked from a script or piped), that's
  /// also unambiguously CLI usage regardless of tty-ness.
  static var shouldRun: Bool {
    CommandLine.arguments.count > 1 || isatty(STDOUT_FILENO) != 0
  }

  static func run() {
    let args = Array(CommandLine.arguments.dropFirst())

    if args.first == "install" {
      installSelf()
      return
    }
    if let first = args.first, ["-h", "--help", "help"].contains(first) {
      printUsage()
      return
    }
    if args.first == "agent" {
      printAgentHelp()
      return
    }

    guard let root = repoRoot() else {
      fail("not inside a git repository")
    }
    let store = DocStore(root: root)

    do {
      switch args.first {
      case ".":
        try openRepo(root: root)
      case nil, "list":
        let rest = args.dropFirst()
        try list(store, sortByDate: rest.contains("-t") || rest.contains("--by-date"))
      case "cat":
        guard args.count > 1 else { fail("usage: rd cat <path>") }
        try cat(store, path: args[1])
      case "edit":
        guard args.count > 1 else { fail("usage: rd edit <path> [file|-]") }
        try edit(store, path: args[1], from: args.count > 2 ? args[2] : nil)
      case "rm", "delete":
        guard args.count > 1 else { fail("usage: rd rm <path>") }
        try remove(store, path: args[1])
      case "export":
        try export(store, to: args.count > 1 ? args[1] : nil)
      case "open":
        guard args.count > 1 else { fail("usage: rd open <path|.>") }
        if args[1] == "." {
          try openRepo(root: root)
        } else {
          try open(store, root: root, path: args[1])
        }
      default:
        // `rd design/auth.md` is shorthand for `rd cat design/auth.md`.
        try cat(store, path: args[0])
      }
    } catch {
      fail(error.localizedDescription)
    }
  }

  private static func repoRoot() -> URL? {
    let git = Git(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    guard let top = try? git.text(["rev-parse", "--show-toplevel"]) else { return nil }
    return URL(fileURLWithPath: top)
  }

  private static func list(_ store: DocStore, sortByDate: Bool) throws {
    let pages = try store.listPages()
    if pages.isEmpty {
      print("No pages yet")
      return
    }
    guard sortByDate else {
      for page in pages { print(page.path) }
      return
    }

    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    let now = Date()

    let modified = try store.lastModifiedTimes()
    let dated = pages
      .map { page in (page, modified[page.path]) }
      .sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }

    for (page, date) in dated {
      guard let date else {
        print(page.path)
        continue
      }
      let relative = formatter.localizedString(for: date, relativeTo: now)
      print("\(page.path)  \u{1B}[2m(\(relative))\u{1B}[0m")
    }
  }

  private static func cat(_ store: DocStore, path: String) throws {
    let content = try store.read(path)
    print(isatty(STDOUT_FILENO) != 0 ? Markdown.colorize(content) : content)
  }

  /// Writes a page from `file`, from stdin when `file` is `-`, or by opening
  /// `$EDITOR` on the page's current content when no file is given. Creates
  /// the page if it doesn't exist yet, same as `DocStore.write` — there is no
  /// separate "new" command.
  private static func edit(_ store: DocStore, path: String, from file: String?) throws {
    let content: String
    switch file {
    case "-":
      content = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    case let file?:
      guard let read = FileManager.default.contents(atPath: file) else {
        fail("can't read \(file)")
      }
      content = String(decoding: read, as: UTF8.self)
    case nil:
      content = try editInteractively(store, path: path)
    }
    try store.write(path: path, content: content)
    print("wrote \(path)")
  }

  /// Opens `$EDITOR` (falling back to `vi`) on a scratch file seeded with the
  /// page's current content, if any, and returns what the editor left behind.
  private static func editInteractively(_ store: DocStore, path: String) throws -> String {
    let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
    let existing = try? store.read(path)

    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("rd-edit-\(UUID().uuidString.prefix(8))")
      .appendingPathComponent((path as NSString).lastPathComponent)
    try FileManager.default.createDirectory(
      at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((existing ?? "").utf8).write(to: scratch)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "\(editor) \"$1\"", "sh", scratch.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      fail("\(editor) exited with status \(process.terminationStatus)")
    }

    guard let data = FileManager.default.contents(atPath: scratch.path) else {
      fail("can't read back \(scratch.path)")
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func remove(_ store: DocStore, path: String) throws {
    try store.delete(path: path)
    print("deleted \(path)")
  }

  /// Dumps every page to a directory (a fresh tmpdir by default), preserving
  /// each page's path. Meant to pair with `rd edit`: export, edit the files
  /// with ordinary tools, then write each changed one back.
  private static func export(_ store: DocStore, to dir: String?) throws {
    let root: URL
    if let dir {
      root = URL(fileURLWithPath: dir)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } else {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rd-export-\(UUID().uuidString.prefix(8))")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    for page in try store.listPages() {
      let fileURL = root.appendingPathComponent(page.path)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(try store.read(page.path).utf8).write(to: fileURL)
    }

    print(root.path)
  }

  private static func open(_ store: DocStore, root: URL, path: String) throws {
    let pages = try store.listPages()
    guard pages.contains(where: { $0.path == path }) else { fail("no such page: \(path)") }
    try openRepo(root: root)
  }

  /// Points the GUI app at `root` and brings it to the front. Sets the same
  /// `UserDefaults` key `AppModel` reads on a cold launch (so quitting and
  /// reopening from Finder resumes this repo), then delivers a `repodocs://`
  /// URL naming `root` — that's what actually opens the repo when the app is
  /// already running, since `AppModel.init()` only runs once per process and
  /// a plain `open <bundle>` on an already-running app just re-activates it
  /// without telling it anything changed.
  private static func openRepo(root: URL) throws {
    UserDefaults.standard.set(root.path, forKey: "repoURL")

    guard let appURL = appBundleURL() else {
      fail("can't find RepoDocs.app to launch")
    }
    var components = URLComponents()
    components.scheme = "repodocs"
    components.host = "open"
    components.queryItems = [URLQueryItem(name: "path", value: root.path)]
    guard let url = components.url else {
      fail("couldn't build an open URL for \(root.path)")
    }

    // `-a <bundle>` targets this exact app bundle directly, rather than
    // relying on `repodocs://` already being registered with LaunchServices
    // (which can lag right after a fresh local build).
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appURL.path, url.absoluteString]
    try process.run()
  }

  /// `rd` runs as a symlink at `~/.local/bin/rd` (see `CLIInstaller`), and
  /// `Bundle.main.bundleURL` doesn't reliably resolve back through that
  /// symlink into `RepoDocs.app`'s bundle structure. Resolve the real
  /// executable path instead and walk up to the enclosing `.app`.
  private static func appBundleURL() -> URL? {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [Int8](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }

    let path = buf.withUnsafeBufferPointer { ptr -> String in
      let bytes = ptr.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      return String(decoding: bytes, as: UTF8.self)
    }
    var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    while url.pathExtension != "app" {
      let parent = url.deletingLastPathComponent()
      guard parent != url else { return nil }
      url = parent
    }
    return url
  }

  private static func installSelf() {
    do {
      try CLIInstaller.install()
      print("Installed 'rd' to ~/.local/bin/rd")
    } catch {
      fail(error.localizedDescription)
    }
  }

  private static func printUsage() {
    print(
      """
      usage: rd [list]                list the docs in the current repo
             rd list -t               list, sorted newest-modified first
             rd cat <path>            print a doc's content
             rd edit <path> [file]    edit a doc: $EDITOR if no file, '-' for stdin, or from a file
             rd rm <path>             delete a doc
             rd export [dir]          dump every doc to a directory (default: a fresh tmpdir)
             rd open <path>           open a doc in the RepoDocs app
             rd open .                open the current repo's folder in the RepoDocs app
             rd <path>                shorthand for 'rd cat <path>'
             rd agent                 usage notes for AI agents editing docs via rd
             rd install               (re)install this helper to ~/.local/bin/rd
      """)
  }

  /// `rd agent` — printed, not executed. There's no MCP server or structured
  /// tool schema here on purpose: an agent that can already run a shell
  /// command doesn't need one, and this is the whole contract in one place.
  private static func printAgentHelp() {
    print(
      """
      rd agent — using rd from an AI agent

      Docs managed by rd are not files in this repo's working tree. They live
      in refs/docs/pages, outside `git status`, outside your working
      directory, invisible to Read/Edit/Write/grep. `rd` is the only interface
      to them — there is no on-disk path to open directly.

      Reading:
        rd                    list every doc
        rd list -t            list, newest edited first
        rd cat <path>         print a doc's content
        rd <path>             shorthand for 'rd cat <path>'

      Editing — recommended flow:
        1. rd export /tmp/some-dir     dump every doc to a scratch directory
        2. edit file(s) there with your normal file tools
        3. rd edit <path> /tmp/some-dir/<path>

      `rd export` with no directory creates and prints a fresh tmpdir, so step
      1 can just be `dir=$(rd export)`.

      For a single doc, skip export and round-trip through a file directly:
        rd cat design/auth.md > /tmp/auth.md
        # edit /tmp/auth.md
        rd edit design/auth.md /tmp/auth.md

      `rd edit <path>` with no file opens the doc in $EDITOR. `rd edit <path> -`
      reads from stdin, so a heredoc works with no scratch file needed:
        rd edit design/auth.md - <<'EOF'
        # Auth
        Sessions are stateless.
        EOF

      Deleting:
        rd rm <path>

      `rd edit` both creates and updates — there's no separate 'new' command.
      Writes are compare-and-swap against the doc ref, so a concurrent writer
      is rejected rather than silently clobbered; on failure, re-read and retry.
      """)
  }

  private static func fail(_ message: String) -> Never {
    fputs("rd: \(message)\n", stderr)
    exit(1)
  }
}
