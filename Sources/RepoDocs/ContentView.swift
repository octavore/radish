import CharmingEditor
import SwiftUI

struct ContentView: View {
  @Bindable var model: AppModel
  @State private var commands = EditorCommands()
  @State private var isNaming = false
  @State private var newPath = ""

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    .navigationTitle(model.repo?.lastPathComponent ?? "RepoDocs")
    .navigationSubtitle(model.status)
    .inspector(isPresented: $model.showInspector) {
      InspectorView(info: model.info)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button {
          model.chooseRepo()
        } label: {
          Label("Open Repository", systemImage: "folder")
        }
        .help("Open a different repository (⌘O)")
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          newPath = ""
          isNaming = true
        } label: {
          Label("New Page", systemImage: "square.and.pencil")
        }
        .disabled(model.repo == nil)
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.showInspector.toggle()
        } label: {
          Label("Info", systemImage: "sidebar.trailing")
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task { await model.save() }
        } label: {
          Label("Save", systemImage: "arrow.down.doc")
        }
        .keyboardShortcut("s")
        .disabled(!model.isDirty)
      }
    }
    .sheet(isPresented: $isNaming) { newPageSheet }
    .alert(
      "Something went wrong",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private var sidebar: some View {
    List(model.tree, children: \.children, selection: $model.selection) { node in
      Label(
        node.name,
        systemImage: node.isFolder ? "folder" : "doc.text")
        .foregroundStyle(node.isFolder ? .secondary : .primary)
        .tag(node.id)
    }
    .overlay {
      if model.repo == nil {
        ContentUnavailableView {
          Label("No repository", systemImage: "folder.badge.questionmark")
        } description: {
          Text("Choose a git repository to store docs in.")
        } actions: {
          Button("Choose…") { model.chooseRepo() }
        }
      } else if model.pages.isEmpty {
        ContentUnavailableView(
          "No pages", systemImage: "doc.text",
          description: Text("Create one to get started."))
      }
    }
    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
  }

  @ViewBuilder
  private var detail: some View {
    if model.selection != nil {
      MarkdownEditor(text: model.editorText)
        .commands(commands)
        .editorFont(.monospaced)
        .editorFontSize(14)
        .focusedSceneValue(\.editorCommands, commands)
    } else {
      ContentUnavailableView(
        "Nothing selected", systemImage: "doc.text",
        description: Text("Pick a page from the sidebar."))
    }
  }

  private var newPageSheet: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New page").font(.headline)
      Text("A path in the doc tree, e.g. `design/auth.md`.")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("design/auth.md", text: $newPath)
        .textFieldStyle(.roundedBorder)
        .frame(width: 320)
        .onSubmit(create)
      HStack {
        Spacer()
        Button("Cancel") { isNaming = false }
          .keyboardShortcut(.cancelAction)
        Button("Create", action: create)
          .keyboardShortcut(.defaultAction)
          .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
  }

  private func create() {
    let path = newPath
    isNaming = false
    Task { await model.createPage(path: path) }
  }

}

/// Carries the focused editor's command channel up to the app's Format menu.
/// Written out longhand rather than with `@Entry`, which needs macOS 15 — this
/// app deploys to 14.
private struct EditorCommandsKey: FocusedValueKey {
  typealias Value = EditorCommands
}

/// Carries the focused *window's* model up to the app menus, so File ▸ Open
/// Repository targets that window and not some global singleton.
private struct AppModelKey: FocusedValueKey {
  typealias Value = AppModel
}

extension FocusedValues {
  var editorCommands: EditorCommands? {
    get { self[EditorCommandsKey.self] }
    set { self[EditorCommandsKey.self] = newValue }
  }

  var appModel: AppModel? {
    get { self[AppModelKey.self] }
    set { self[AppModelKey.self] = newValue }
  }
}
