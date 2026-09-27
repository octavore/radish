import Crumpet
import SwiftUI

/// RepoDocs ▸ Settings (⌘,). A `TabView` shell, per the macOS app checklist:
/// one `Label` per tab, a fixed frame, top-aligned content. Every value is
/// persisted via `@AppStorage` under keys `ContentView` reads directly, so a
/// change here restyles every open window's editor live.
struct SettingsView: View {
  var body: some View {
    // Each tab sets its own size; the Settings window resizes to match.
    //
    // No outer padding: each tab is a grouped `Form` that brings its own
    // insets, and padding here would leave a dead margin the Typography tab's
    // scroller and clipped rows show through.
    TabView {
      GeneralSettingsView()
        .frame(width: 460, height: 440, alignment: .top)
        .tabItem { Label("General", systemImage: "gearshape") }
      ThemeSettingsView()
        .frame(width: 560, height: 560, alignment: .top)
        .tabItem { Label("Theme", systemImage: "paintpalette") }
      // Tall enough that the seven-row form fits without its own scroller.
      TypographySettingsView()
        .frame(width: 460, height: 440, alignment: .top)
        .tabItem { Label("Typography", systemImage: "textformat.size") }
    }
    .navigationTitle("RepoDocs Settings")
  }
}

/// General app settings. Currently just the `rd` command line helper: a
/// symlink at `~/.local/bin/rd` pointing at the binary bundled in this app,
/// the same thing the "Install 'rd' Command Line Tool" menu item creates.
private struct GeneralSettingsView: View {
  @State private var installed = CLIInstaller.isInstalled
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section("Command Line Tool") {
        Text(
          "Symlink `rd` into `\(CLIInstaller.linkPath)` so it's on your `PATH`. "
            + "Make sure `~/.local/bin` is in your shell's `PATH`."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        HStack {
          Toggle("Install `rd` helper", isOn: toggleBinding)
            .toggleStyle(.switch)
          Spacer()
          if installed {
            Text("Installed").font(.caption).foregroundStyle(.secondary)
          }
        }
        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { installed = CLIInstaller.isInstalled }
  }

  private var toggleBinding: Binding<Bool> {
    Binding(
      get: { installed },
      set: { want in
        errorMessage = nil
        do {
          if want {
            try CLIInstaller.install()
          } else {
            try CLIInstaller.uninstall()
          }
          installed = CLIInstaller.isInstalled
        } catch {
          errorMessage = error.localizedDescription
          installed = CLIInstaller.isInstalled
        }
      })
  }
}

/// Crumpet's drop-in `EditorThemeForm` with the Custom theme enabled, bound to
/// a theme, an appearance, and custom colors persisted under their own
/// `@AppStorage` keys.
private struct ThemeSettingsView: View {
  @AppStorage(AppSettings.themeKey) private var theme = EditorTheme.system
  @AppStorage(AppSettings.appearanceKey) private var appearance = EditorAppearance.system
  @AppStorage(AppSettings.customColorsKey) private var customColors = EditorCustomColors()

  var body: some View {
    // Grouped so the theme cards and preview span the full width. A grouped
    // form also scrolls when the Custom theme's rows exceed the window.
    Form {
      EditorThemeForm(theme: $theme, appearance: $appearance, customColors: $customColors)
    }
    .formStyle(.grouped)
  }
}

/// Editor typography. The rows come straight from Crumpet's drop-in
/// `EditorSettingsForm` (font, sizes, ratios, line height, max width, marker
/// reveal, restore-defaults), bound to the one `EditorSettings` value
/// `ContentView` reads to style the editor.
private struct TypographySettingsView: View {
  @AppStorage(AppSettings.editorSettingsKey) private var settings = AppSettings.defaultEditorSettings

  var body: some View {
    Form {
      Section("Typography") {
        EditorSettingsForm(settings: $settings)
      }
    }
    .formStyle(.grouped)
    // Covers the sliders and the pickers with one call site. See
    // `AppSettings.editorChannel` for why the stored value isn't enough on its
    // own during a drag.
    .onChange(of: settings) { _, new in
      AppSettings.editorChannel.send(new)
    }
  }
}

/// Keys shared between `SettingsView` (which writes them) and `ContentView`
/// (which reads them to style the editor).
enum AppSettings {
  /// `@AppStorage` key holding the Crumpet `EditorTheme`.
  static let themeKey = "editorTheme"

  /// `@AppStorage` key holding the Crumpet `EditorAppearance`.
  static let appearanceKey = "editorAppearance"

  /// `@AppStorage` key holding the Crumpet `EditorCustomColors`.
  static let customColorsKey = "customColorScheme"

  /// `@AppStorage` key backing the Crumpet `EditorSettings` bundle.
  static let editorSettingsKey = "editorSettings"

  /// Carries a typography change straight to every open editor.
  ///
  /// `@AppStorage` alone leaves a slider drag invisible until the mouse comes
  /// up: SwiftUI doesn't re-evaluate a view in another window while the drag's
  /// event-tracking run loop runs, so the whole scrub arrives at once at the
  /// end. The stored value stays the source of truth (it's what a cold launch
  /// and every change outside a drag read); this only makes the scrub visible
  /// while it happens.
  ///
  /// One instance for the app: `Settings` and `WindowGroup` are separate
  /// scenes with no shared state, and every open window's editor subscribes.
  @MainActor static let editorChannel = EditorSettingsChannel()

  /// Seed for a fresh install: RepoDocs opens in monospaced at 14pt, matching
  /// the fixed styling it used before the settings became tunable.
  static let defaultEditorSettings = EditorSettings(font: .monospaced, fontSize: 14)
}
