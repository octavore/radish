import CharmingEditor
import SwiftUI

@main
struct RepoDocsApp: App {
  var body: some Scene {
    // The model lives in RootView, not here, so every window (and therefore
    // every tab) owns an independent repo. Hoisting it to App would make ⌘N
    // open a second view of the *same* repo.
    WindowGroup {
      RootView()
      // .frame(minWidth: 720, minHeight: 460)
    }
    .commands {
      CommandGroup(after: .newItem) {
        OpenRepositoryCommand()
      }
      FormatCommands()
    }
  }
}

struct RootView: View {
  @State private var model = AppModel()

  var body: some View {
    ContentView(model: model)
      .focusedSceneValue(\.appModel, model)
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
