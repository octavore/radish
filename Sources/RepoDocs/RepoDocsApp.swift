import CharmingEditor
import SwiftUI

/// The GUI. `rd` is a separate Rust binary riding along in
/// `Contents/MacOS/rd` (see `CLIInstaller`), so this executable no longer has
/// to decide at launch whether it's a terminal tool or an app.
@main
struct RepoDocsApp: App {
  var body: some Scene {
    // The model lives in RootView, not here, so every window (and therefore
    // every tab) owns an independent repo. Hoisting it to App would make ⌘N
    // open a second view of the *same* repo.
    //
    // Keyed `for: URL.self` rather than a plain `WindowGroup` so `rd open .`
    // can target a specific window: `openWindow(value:)` below focuses the
    // existing window for that repo if there is one, instead of always
    // spawning a new one. A window opened with no value (cold launch, ⌘N)
    // gets `repoURL == nil` and falls back to `AppModel`'s own last-opened-repo
    // logic.
    WindowGroup(for: URL.self) { $repoURL in
      RootView(repoURL: repoURL)
      // .frame(minWidth: 720, minHeight: 460)
    }
    // No native title bar: the window's only chrome is `ContentView`'s own
    // floating bar, which can scroll away with the document. A native toolbar
    // spans the sidebar as well as the detail column and can't hide over just
    // one of them, so the two can't be reconciled — this app picks the one
    // that hides.
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .appInfo) {
        InstallCLICommand()
      }
      CommandGroup(after: .newItem) {
        OpenRepositoryCommand()
      }
      FormatCommands()
    }
    Settings {
      SettingsView()
    }
  }
}

/// RepoDocs ▸ Install 'rd' Command Line Tool. Symlinks the `rd` binary bundled
/// alongside this app to `~/.local/bin/rd`, mirroring how `code`/`subl` install
/// their shell helpers.
struct InstallCLICommand: View {
  @State private var installed = CLIInstaller.isInstalled
  @State private var errorMessage: String?

  var body: some View {
    Button(installed ? "'rd' Command Line Tool Installed" : "Install 'rd' Command Line Tool…") {
      do {
        try CLIInstaller.install()
        installed = true
      } catch {
        errorMessage = error.localizedDescription
      }
    }
    .disabled(installed)
    .alert(
      "Couldn't Install 'rd'", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil }),
      presenting: errorMessage
    ) { _ in
      Button("OK") {}
    } message: { message in
      Text(message)
    }
  }
}

struct RootView: View {
  @State private var model = AppModel()
  @Environment(\.openWindow) private var openWindow
  /// Non-nil when this window was opened for a specific repo (`rd open .`,
  /// or a repo already open in an existing window that `openWindow(value:)`
  /// re-focused). Nil for a plain new window, which falls back to
  /// `AppModel.init()`'s own last-opened-repo restoration.
  let repoURL: URL?

  var body: some View {
    ContentView(model: model)
      .focusedSceneValue(\.appModel, model)
      .onAppear {
        if let repoURL { model.open(repoURL) }
      }
      // `onOpenURL` is a `View` modifier, not a `Scene` one, so it's here
      // rather than on the `WindowGroup` itself; it fires regardless of
      // which window happens to be current, and just asks SwiftUI to
      // open (or focus, since windows are keyed `for: URL.self`) the
      // requested repo's window — see `CLI.openRepo`.
      .onOpenURL { url in
        guard let path = Self.repoPath(from: url) else { return }
        openWindow(value: URL(fileURLWithPath: path))
      }
  }

  /// Parses `repodocs://open?path=<repo path>`, as sent by `rd open .`/`rd .`.
  private static func repoPath(from url: URL) -> String? {
    guard url.scheme == "repodocs", url.host == "open" else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first { $0.name == "path" }?
      .value
  }
}

/// File ▸ Open Repository. Acts on the focused window, so it replaces that
/// window's repo rather than some global one.
struct OpenRepositoryCommand: View {
  @FocusedValue(\.appModel) private var model

  var body: some View {
    Button("Open Repository…") { model?.chooseRepo() }
      .keyboardShortcut("o")
      .disabled(model == nil)
  }
}

/// Format menu, reaching the focused window's editor through the focused-scene
/// value so the menu stays decoupled from the view.
struct FormatCommands: Commands {
  @FocusedValue(\.editorCommands) private var commands

  var body: some Commands {
    CommandMenu("Format") {
      Button("Bold") { commands?.send(.toggleBold) }
        .keyboardShortcut("b")
      Button("Italic") { commands?.send(.toggleItalic) }
        .keyboardShortcut("i")
      Divider()
      ForEach(TextStyle.allCases) { style in
        Button(style.displayName) { commands?.send(.setBlockStyle(style)) }
          .keyboardShortcut(style.shortcutKey, modifiers: [.command, .option])
      }
    }
  }
}
