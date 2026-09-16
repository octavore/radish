import AppKit
import Crumpet
import SwiftUI

/// RepoDocs ▸ Settings (⌘,). A `TabView` shell, per the macOS app checklist:
/// one `Label` per tab, a fixed frame, top-aligned content. Every value is
/// persisted via `@AppStorage` under keys `ContentView` reads directly, so a
/// change here restyles every open window's editor live; the only staged field
/// is the Slack theme string, which applies on submit.
struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gearshape") }
      ThemeSettingsView()
        .tabItem { Label("Theme", systemImage: "paintpalette") }
      TypographySettingsView()
        .tabItem { Label("Typography", systemImage: "textformat.size") }
    }
    // No outer padding: each tab is a grouped `Form` that brings its own
    // insets, and padding here would leave a dead margin the Typography tab's
    // scroller and clipped rows show through.
    //
    // Tall enough that the Typography tab's seven-row form fits without its
    // own scroller; General and Theme just top-align in the extra space.
    .frame(width: 460, height: 440, alignment: .top)
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

/// The editor color scheme: one `ColorPicker` per construct, plus a Slack theme
/// string as a shortcut for setting all six at once.
///
/// While the stored value is empty the pickers show RepoDocs' adaptive default
/// (`EditorColorScheme.repoDocs`) and the editor keeps using it verbatim, so
/// the light/dark adaptation survives. Touching any picker, or applying a theme
/// string, freezes all six to concrete hex.
private struct ThemeSettingsView: View {
  @AppStorage(AppSettings.themeKey) private var themeRaw = ""
  @State private var slackDraft = ""
  @State private var slackError: String?

  private var theme: EditorTheme { EditorTheme(rawValue: themeRaw) ?? .current }

  var body: some View {
    Form {
      Section("Colors") {
        colorRow("Text", \.text)
        colorRow("Heading", \.heading)
        colorRow("Code", \.code)
        colorRow("Bold", \.bold)
        colorRow("Italic", \.italic)
        colorRow("Background", \.background)
      }
      Section("Import Theme") {
        Text("Paste 8 comma-separated hex colors, Slack-style, to set every color at once.")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("#282a36, #3e4451, #bd93f9, #f8f8f2, #44475a, #f8f8f2, #50fa7b, #ff79c6", text: $slackDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(applySlack)
        HStack {
          Button("Apply", action: applySlack)
            .disabled(slackDraft.trimmingCharacters(in: .whitespaces).isEmpty)
          if !themeRaw.isEmpty {
            Button("Reset to Default") {
              themeRaw = ""
              slackDraft = ""
              slackError = nil
            }
          }
          Spacer()
        }
        if let slackError {
          Text(slackError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
  }

  /// One picker bound to a single hex field of the stored theme. The getter
  /// resolves from whatever is effective now (default or stored); the setter
  /// writes the whole struct back, promoting an empty store to explicit hex.
  private func colorRow(_ label: String, _ key: WritableKeyPath<EditorTheme, String>)
    -> some View
  {
    ColorPicker(
      label,
      selection: Binding(
        get: { Color(hex: theme[keyPath: key]) ?? .primary },
        set: { newColor in
          var next = theme
          next[keyPath: key] = newColor.hexRGB
          themeRaw = next.rawValue
        }),
      supportsOpacity: false)
  }

  /// Parses `slackDraft` as a Slack theme string and, only on success, freezes
  /// all six colors to its values. An unparseable paste leaves the store alone.
  private func applySlack() {
    guard let parsed = EditorTheme(slackString: slackDraft) else {
      slackError = "Expected 8 hex colors in Slack's import order."
      return
    }
    slackError = nil
    themeRaw = parsed.rawValue
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

/// Keys and derivation shared between `SettingsView` (which writes them) and
/// `ContentView` (which reads them to style the editor).
enum AppSettings {
  /// `@AppStorage` key holding an `EditorTheme` as JSON; empty means "use the
  /// adaptive default".
  static let themeKey = "editorTheme"

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

  /// The active color scheme: the stored `EditorTheme` if one is set, otherwise
  /// RepoDocs' built-in adaptive default.
  static func colorScheme(from themeRaw: String) -> EditorColorScheme {
    EditorTheme(rawValue: themeRaw)?.colorScheme ?? .repoDocs
  }
}

/// The six editor colors as hex strings, so the whole set backs one
/// `@AppStorage` value and round-trips through both the `ColorPicker` rows and
/// a pasted Slack theme string.
struct EditorTheme: Equatable {
  var text: String
  var heading: String
  var code: String
  var bold: String
  var italic: String
  var background: String

  var colorScheme: EditorColorScheme {
    EditorColorScheme(
      text: Color(hex: text) ?? .primary,
      heading: Color(hex: heading),
      code: Color(hex: code),
      bold: Color(hex: bold),
      italic: Color(hex: italic),
      background: Color(hex: background) ?? .editorBackground)
  }

  /// A snapshot of RepoDocs' adaptive default, resolved to concrete hex. Used
  /// to seed the pickers and as the base when the user edits just one color.
  static var current: EditorTheme {
    let s = EditorColorScheme.repoDocs
    return EditorTheme(
      text: s.text.hexRGB,
      heading: s.heading.hexRGB,
      code: s.code.hexRGB,
      bold: s.bold.hexRGB,
      italic: s.italic.hexRGB,
      background: s.background.hexRGB)
  }

  /// Builds a theme from a pasted Slack theme string, or nil if it doesn't
  /// parse into eight hex colors.
  init?(slackString raw: String) {
    let parts = EditorColorScheme.splitThemeString(raw)
    guard let s = EditorColorScheme(themeStrings: parts) else { return nil }
    self.init(
      text: s.text.hexRGB,
      heading: s.heading.hexRGB,
      code: s.code.hexRGB,
      bold: s.bold.hexRGB,
      italic: s.italic.hexRGB,
      background: s.background.hexRGB)
  }

  init(
    text: String, heading: String, code: String, bold: String, italic: String,
    background: String
  ) {
    self.text = text
    self.heading = heading
    self.code = code
    self.bold = bold
    self.italic = italic
    self.background = background
  }
}

extension EditorTheme: RawRepresentable {
  /// JSON mirror used only for `@AppStorage`. Kept separate from `EditorTheme`
  /// so the standard `RawRepresentable` Codable defaults never route
  /// `encode(to:)` back through `rawValue`, which recurses until the stack
  /// overflows.
  private struct Stored: Codable {
    var text: String
    var heading: String
    var code: String
    var bold: String
    var italic: String
    var background: String
  }

  init?(rawValue: String) {
    guard
      let data = rawValue.data(using: .utf8),
      let s = try? JSONDecoder().decode(Stored.self, from: data)
    else { return nil }
    self.init(
      text: s.text, heading: s.heading, code: s.code, bold: s.bold,
      italic: s.italic, background: s.background)
  }

  var rawValue: String {
    let s = Stored(
      text: text, heading: heading, code: code, bold: bold, italic: italic,
      background: background)
    guard
      let data = try? JSONEncoder().encode(s),
      let string = String(data: data, encoding: .utf8)
    else { return "" }
    return string
  }
}

extension Color {
  /// `#rrggbb` in sRGB. Resolves dynamic and system colors to their current
  /// value, so a `ColorPicker` row always has a concrete hex to persist.
  var hexRGB: String {
    let resolved = NSColor(self).usingColorSpace(.sRGB) ?? .black
    let r = Int((resolved.redComponent * 255).rounded())
    let g = Int((resolved.greenComponent * 255).rounded())
    let b = Int((resolved.blueComponent * 255).rounded())
    return String(format: "#%02x%02x%02x", r, g, b)
  }
}
