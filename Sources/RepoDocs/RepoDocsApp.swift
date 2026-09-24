import AppKit
import Crumpet
import SwiftUI

/// The repositories currently open in a window, keyed by canonical top-level
/// path. `rd open .` on a repo that already has a window focuses that window
/// instead of spawning a second one, and it works no matter how the first
/// window opened it (URL, last-session restore, or the Open panel).
@MainActor
final class OpenRepos {
  private final class WeakWindow {
    weak var value: NSWindow?
  }

  private var windows: [String: WeakWindow] = [:]

  /// One instance for the app. `WindowGroup` and `Settings` are separate scenes
  /// with no shared state, and every window's `RootView` registers here.
  static let shared = OpenRepos()

  func register(_ path: String, window: NSWindow) {
    let box = windows[path] ?? WeakWindow()
    box.value = window
    windows[path] = box
  }

  func unregister(_ path: String) {
    windows[path] = nil
  }

  func contains(_ path: String) -> Bool {
    window(for: path) != nil
  }

  /// Brings the window for `path` to the front. Returns false when no live
  /// window is registered, so the caller can fall back to opening one.
  @discardableResult
  func focus(_ path: String) -> Bool {
    guard let window = window(for: path) else { return false }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return true
  }

  private func window(for path: String) -> NSWindow? {
    guard let box = windows[path] else { return nil }
    guard let window = box.value else {
      windows[path] = nil
      return nil
    }
    return window
  }
}

/// Namespace so call sites read `AppWindows.openRepos`.
enum AppWindows {
  @MainActor static var openRepos: OpenRepos { .shared }
}

/// `NavigationSplitView` autosaves its split view frames by window index, so a
/// new window can take another window's sidebar width and ignore the column's
/// limits. `ContentView.sidebarWidth` owns that width, so the autosave is off.
@MainActor
enum SplitViewAutosave {
  /// Clears the autosave name of every split view in `window`.
  static func disable(in window: NSWindow) {
    if let root = window.contentView { clearNames(in: root) }
  }

  private static func clearNames(in view: NSView) {
    if let split = view as? NSSplitView { split.autosaveName = nil }
    for subview in view.subviews { clearNames(in: subview) }
  }
}

/// Hands back the `NSWindow` hosting a SwiftUI view once it joins the window.
struct WindowAccessor: NSViewRepresentable {
  var onChange: (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { onChange(view.window) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { onChange(view.window) }
  }
}

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
    // Keyed `for: URL.self` so `rd open .` can target a specific window. A
    // window opened with no value (cold launch, ⌘N) gets `repoURL == nil` and
    // falls back to `AppModel`'s last-opened-repo restoration. SwiftUI only
    // dedupes windows whose `openWindow(value:)` values match, which a restored
    // or panel-opened window never carries, so `OpenRepos` tracks every open
    // repo by canonical path and `RootView` consults it before opening.
    WindowGroup(for: URL.self) { $repoURL in
      RootView(repoURL: repoURL)
      // .frame(minWidth: 720, minHeight: 460)
    }
    // No native title bar: the window's only chrome is `ContentView`'s own
    // floating bar, which can scroll away with the document. A native toolbar
    // spans the sidebar as well as the detail column and can't hide over just
    // one of them, so the two can't be reconciled; this app picks the one
    // that hides.
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .appInfo) {
        InstallCLICommand()
      }
      CommandGroup(after: .newItem) {
        OpenRepositoryCommand()
        GoToPageCommand()
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
  @State private var window: NSWindow?
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss
  /// Non-nil when this window was opened for a specific repo (`rd open .`, or a
  /// repo already open in a window that `openWindow(value:)` re-focused). Nil
  /// for a plain new window, which falls back to `restoreLastRepo`.
  let repoURL: URL?

  var body: some View {
    ContentView(model: model)
      .focusedSceneValue(\.appModel, model)
      .background(WindowAccessor { window = $0 })
      .task(id: repoURL) {
        if let repoURL {
          if await model.focusIfOpenElsewhere(repoURL) {
            dismiss()
          } else {
            await model.open(repoURL)
          }
        } else {
          await model.restoreLastRepo()
        }
      }
      // Keep the open-repos registry in step with this window: whichever of the
      // window handle or the resolved repo arrives second completes the entry,
      // and closing the window (or swapping its repo) clears the old one.
      .onChange(of: window) { _, new in
        // AppKit's window-state restoration was widening the sidebar on
        // every relaunch (see `ContentView.sidebarWidth`, which now owns
        // that value). SwiftUI has no scene modifier for this, so it's
        // disabled on the NSWindow directly. Repo, selection, and editor
        // state still restore through `AppModel` and `@AppStorage`; only
        // window position and size are lost across quits.
        new?.isRestorable = false
        if let new { SplitViewAutosave.disable(in: new) }
        syncRegistration()
      }
      .onChange(of: model.repo) { old, _ in
        if let old { AppWindows.openRepos.unregister(old.path) }
        syncRegistration()
      }
      .onDisappear {
        if let repo = model.repo { AppWindows.openRepos.unregister(repo.path) }
      }
      // `onOpenURL` is a `View` modifier, not a `Scene` one, so it's here
      // rather than on the `WindowGroup` itself. It fires in whichever window
      // receives the event; see `CLI.openRepo`.
      .onOpenURL { url in
        guard let path = Self.repoPath(from: url) else { return }
        Task {
          let target = URL(fileURLWithPath: path)
          let root = await model.repoRoot(for: target) ?? target
          // Focus a window that already holds the repo. `openWindow(value:)`
          // only dedupes against windows opened with the same value.
          if AppWindows.openRepos.focus(root.path) { return }
          // Fill an empty window (cold launch or ⌘N) rather than opening a
          // second one, which would restore the last session's repo.
          if repoURL == nil, model.repo == nil {
            await model.open(root)
          } else {
            openWindow(value: root)
          }
        }
      }
      // Delivers `repodocs://` URLs to an existing window instead of a new one.
      .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
  }

  private func syncRegistration() {
    guard let window, let repo = model.repo else { return }
    AppWindows.openRepos.register(repo.path, window: window)
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

/// File ▸ Go to Page. Toggles the focused window's fuzzy page palette.
struct GoToPageCommand: View {
  @FocusedValue(\.appModel) private var model

  var body: some View {
    Button("Go to Page…") { model?.showPalette.toggle() }
      .keyboardShortcut("k")
      .disabled(model?.repo == nil)
  }
}

/// Format menu, reaching the focused window's editor through the focused-scene
/// value so the menu stays decoupled from the view.
struct FormatCommands: Commands {
  @FocusedValue(\.editorCommands) private var commands
  @FocusedValue(\.appModel) private var model

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
      Divider()
      Button("Reformat Document") { Task { await model?.formatDocument() } }
        .keyboardShortcut("f", modifiers: [.command, .option, .shift])
        .disabled(model?.selection == nil)
    }
  }
}
