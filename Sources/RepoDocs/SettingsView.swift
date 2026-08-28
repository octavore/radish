import CharmingEditor
import SwiftUI

/// RepoDocs ▸ Settings (⌘,). A `TabView` shell, per the macOS app checklist:
/// one `Label` per tab, a fixed frame, top-aligned content. Every value is
/// persisted via `@AppStorage` under keys `ContentView` reads directly, so a
/// change here restyles every open window's editor live — there's no separate
/// "apply" step beyond the theme field, which stages its paste until parsed.
struct SettingsView: View {
  var body: some View {
    TabView {
      ThemeSettingsView()
        .tabItem { Label("Theme", systemImage: "paintpalette") }
      TypographySettingsView()
        .tabItem { Label("Typography", systemImage: "textformat.size") }
    }
    .padding(20)
    .frame(width: 460, height: 260, alignment: .top)
    .navigationTitle("RepoDocs Settings")
  }
}

/// The editor color scheme, pasted Slack-style as one comma-separated hex list.
private struct ThemeSettingsView: View {
  @AppStorage(AppSettings.themeKey) private var themeString = ""
  @State private var themeDraft = ""
  @State private var themeError: String?

  var body: some View {
    Form {
      Section("Theme") {
        Text(
          "Paste 6 comma-separated hex colors — text, heading, code, bold, italic, background — Slack-style."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        TextField("#f8f8f2, #bd93f9, #ff79c6, #ffb86c, #8be9fd, #282a36", text: $themeDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(applyTheme)
        HStack {
          Button("Apply Theme", action: applyTheme)
            .disabled(themeDraft.trimmingCharacters(in: .whitespaces).isEmpty)
          if !themeString.isEmpty {
            Button("Reset to Default") {
              themeString = ""
              themeDraft = ""
              themeError = nil
            }
          }
          Spacer()
        }
        if let themeError {
          Text(themeError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { themeDraft = themeString }
  }

  /// Parses `themeDraft` and, only if it's a valid 6-color theme, persists it
  /// verbatim (so reopening Settings shows back what was pasted) and clears
  /// any prior error. An invalid paste leaves the stored theme untouched.
  private func applyTheme() {
    let parts = EditorColorScheme.splitThemeString(themeDraft)
    guard EditorColorScheme(themeStrings: parts) != nil else {
      themeError = "Expected 6 hex colors: text, heading, code, bold, italic, background."
      return
    }
    themeError = nil
    themeString = themeDraft
  }
}

/// Heading and code sizes, each a multiplier on the base editor font size.
private struct TypographySettingsView: View {
  @AppStorage(Typography.titleRatioDefaultsKey) private var titleRatio = Double(
    Typography.defaultTitleRatio)
  @AppStorage(Typography.codeRatioDefaultsKey) private var codeRatio = Double(
    Typography.defaultCodeRatio)

  var body: some View {
    Form {
      Section("Typography") {
        Stepper(value: $titleRatio, in: Typography.titleRatioRange, step: 0.05) {
          Text("Title Size: \(titleRatio, specifier: "%.2f")×")
        }
        Stepper(value: $codeRatio, in: Typography.codeRatioRange, step: 0.05) {
          Text("Code Size: \(codeRatio, specifier: "%.2f")×")
        }
        Button("Reset to Defaults") {
          titleRatio = Double(Typography.defaultTitleRatio)
          codeRatio = Double(Typography.defaultCodeRatio)
        }
        .disabled(
          titleRatio == Double(Typography.defaultTitleRatio)
            && codeRatio == Double(Typography.defaultCodeRatio))
      }
    }
    .formStyle(.grouped)
  }
}

/// Keys and derivation shared between `SettingsView` (which writes them) and
/// `ContentView` (which reads them to style the editor).
enum AppSettings {
  static let themeKey = "editorTheme"

  /// The active color scheme: the persisted theme string if it parses,
  /// otherwise RepoDocs' built-in default.
  static func colorScheme(from themeString: String) -> EditorColorScheme {
    EditorColorScheme(themeStrings: EditorColorScheme.splitThemeString(themeString)) ?? .repoDocs
  }
}
