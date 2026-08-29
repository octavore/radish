import Foundation

enum CLIInstallError: Error, LocalizedError {
  case missingBundledTool
  case pathNotWritable(String)

  var errorDescription: String? {
    switch self {
    case .missingBundledTool: "This copy of RepoDocs has no bundled 'rd' to install"
    case .pathNotWritable(let path): "Couldn't create \(path)"
    }
  }
}

/// Installs `rd`, a symlink to the Rust CLI that ships inside the app bundle at
/// `Contents/MacOS/rd` (put there by `[[build.copy]]` in `strudel.toml`).
///
/// `rd` used to be a symlink back to this same executable, with the app
/// deciding at launch whether it was a GUI or a CLI. It's now its own binary
/// built from `crates/rd`, so the link points at that instead.
enum CLIInstaller {
  private static var linkURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".local/bin/rd")
  }

  /// Where the symlink lives, for display in Settings.
  static var linkPath: String { linkURL.path }

  /// The bundled CLI, a sibling of this app's own executable.
  private static var toolURL: URL? {
    guard let executable = Bundle.main.executableURL else { return nil }
    let tool = executable.deletingLastPathComponent().appending(path: "rd")
    return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
  }

  static var isInstalled: Bool {
    guard let target = toolURL,
      let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
    else { return false }
    return resolved == target.path
  }

  static func install() throws {
    guard let target = toolURL else { throw CLIInstallError.missingBundledTool }

    let binDir = linkURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    } catch {
      throw CLIInstallError.pathNotWritable(binDir.path)
    }

    // symlinkMetadata, not fileExists: a link pointing at a deleted target
    // still occupies the name and still has to go.
    if (try? FileManager.default.attributesOfItem(atPath: linkURL.path)) != nil
      || (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) != nil
    {
      try? FileManager.default.removeItem(at: linkURL)
    }
    try FileManager.default.createSymbolicLink(
      atPath: linkURL.path, withDestinationPath: target.path)
  }

  /// Removes the symlink if it points at our bundled tool. Leaves anything
  /// else at that path alone.
  static func uninstall() throws {
    guard isInstalled else { return }
    try FileManager.default.removeItem(at: linkURL)
  }
}
