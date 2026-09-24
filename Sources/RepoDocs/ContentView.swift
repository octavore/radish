import AppKit
import Crumpet
import RepoDocsCore
import SwiftUI

extension EditorColorScheme {
  /// RepoDocs' editor palette. Each accent is one of SwiftUI's system colors,
  /// so it's already dynamic (adapts to light/dark) with no extra work.
  static let repoDocs = EditorColorScheme(
    heading: .indigo,
    code: .pink,
    bold: .orange,
    italic: .teal)
}

struct ContentView: View {
  @Bindable var model: AppModel
  @State private var commands = EditorCommands()
  @AppStorage(AppSettings.themeKey) private var themeString = ""
  @AppStorage(AppSettings.editorSettingsKey) private var editorSettings = AppSettings.defaultEditorSettings
  @State private var isNaming = false
  @State private var newPath = ""
  @State private var isNamingFolder = false
  @State private var newFolderPath = ""
  /// Whether the floating doc toolbar is showing. Driven by scroll *direction*
  /// rather than absolute position (see `handleScroll`): scrolling down hides
  /// the bar, and a deliberate scroll back up shows it again at any point in
  /// the document.
  @State private var showToolbar = true
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  /// Drives the sidebar's `ideal` width instead of letting AppKit's
  /// window-state restoration set it. Restoration rounded the saved
  /// proportion to pixels with no cap, so the column grew wider on each
  /// relaunch. See `NSWindow.isRestorable = false` in `RepoDocsApp`.
  @AppStorage("sidebarWidth") private var sidebarWidth: Double = 220
  /// The last offset `handleScroll` saw, and how far the current unbroken run
  /// in one direction has travelled. Plain properties on a class box, not
  /// `@State`: they change on every scroll tick and only `showToolbar` should
  /// ever invalidate the view.
  @State private var scrollTracker = ScrollTracker()

  /// Height reserved for `docToolbar`, both as the editor's top content inset
  /// and as the distance the bar slides up by when hiding.
  private static let toolbarHeight: CGFloat = 48

  private static let sidebarWidthRange: ClosedRange<CGFloat> = 180...320

  /// Shared by the sidebar toggle and the doc bar's leading inset so the two
  /// move as one. Sidebar shows/hides are a size change rather than a spring
  /// gesture, so an ease-out reads better than a bouncy default.
  private static let sidebarAnimation = Animation.easeOut(duration: 0.25)

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
    } detail: {
      detail
    }
    // Still set even though `.hiddenTitleBar` draws no title: it names the
    // window in the Window menu and the ⌘-Tab window switcher.
    .navigationTitle(model.repo?.lastPathComponent ?? "RepoDocs")
    .navigationSubtitle(model.status)
    .inspector(isPresented: $model.showInspector) {
      InspectorView(info: model.info) { revision in
        Task { await model.showDiff(against: revision) }
      }
      .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
      // The hidden title bar still reserves its safe area at the top of the
      // inspector column, pushing the first section down. Reclaim it so the
      // content starts flush under the window's top edge.
      .ignoresSafeArea(.container, edges: .top)
    }
    .sheet(isPresented: $isNaming) { newPageSheet }
    .sheet(isPresented: $isNamingFolder) { newFolderSheet }
    .sheet(
      isPresented: Binding(
        get: { model.diff != nil },
        set: { if !$0 { model.diff = nil } })
    ) {
      if let diff = model.diff {
        DiffView(diff: diff)
      }
    }
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
    List(selection: $model.selection) {
      if let repoName = model.repo?.lastPathComponent {
        Section(repoName) { sidebarRows }
      } else {
        sidebarRows
      }
    }
    .contextMenu { newItemMenu(in: "") }
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
    .navigationSplitViewColumnWidth(
      min: Self.sidebarWidthRange.lowerBound, ideal: sidebarWidth,
      max: Self.sidebarWidthRange.upperBound)
    // NavigationSplitView adds its own toggle at the sidebar's top edge, which
    // duplicates `docToolbar`'s. The floating bar owns that job.
    .toolbar(removing: .sidebarToggle)
    .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
    // Stores the user's manual resizes in `sidebarWidth`, clamped to the
    // column's range. Widths seen while the sidebar is collapsed are skipped.
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
      guard columnVisibility != .detailOnly else { return }
      let range = Self.sidebarWidthRange
      sidebarWidth = min(max(newWidth, range.lowerBound), range.upperBound)
    }
  }

  /// A refresh control pinned to the sidebar's bottom edge. `rd edit` and any
  /// other writer advances the page ref underneath a window that's already
  /// open; this rereads it on demand.
  @ViewBuilder
  private var sidebarFooter: some View {
    if model.repo != nil {
      HStack {
        Button {
          Task { await model.refresh() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("r")
        .help("Reload pages from git")
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.bar)
    }
  }

  /// The folder/page outline itself, without the enclosing repo-name section.
  @ViewBuilder
  private var sidebarRows: some View {
    OutlineGroup(model.tree, children: \.children) { node in
      Label(
        node.name,
        systemImage: node.isFolder ? "folder" : "doc.text")
        .foregroundStyle(node.isFolder ? .secondary : .primary)
        .tag(node.id)
        .contextMenu { newItemMenu(in: node.folderPrefix) }
    }
  }

  private var detail: some View {
    ZStack(alignment: .top) {
      editorContent
      // Conditional rather than faded in place: `.bar` is a vibrancy material,
      // and a material that's merely transparent still gets blurred every
      // frame, over a document that's changing every frame, only to be
      // composited at zero alpha. Taking it out of the tree ends that work for
      // the whole time the bar is away, which is most of a read.
      if showToolbar {
        docToolbar
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.2), value: showToolbar)
    // A hidden title bar still reserves its safe area. Reclaim it so the bar
    // starts at the window's own top edge; the bar *is* this window's title
    // bar, and the document scrolls under it from there.
    .ignoresSafeArea(.container, edges: .top)
  }

  @ViewBuilder
  private var editorContent: some View {
    if model.selection != nil {
      MarkdownEditor(text: model.editorText)
        .commands(commands)
        .editorSettings(editorSettings)
        .editorSettingsChannel(AppSettings.editorChannel)
        .editorColorScheme(AppSettings.colorScheme(from: themeString))
        .editorTopContentInset(Self.toolbarHeight)
        .onScroll(handleScroll)
        .focusedSceneValue(\.editorCommands, commands)
        // A freshly opened doc starts scrolled to its top, whatever the
        // previous doc's offset was.
        .onChange(of: model.selection) {
          scrollTracker.reset()
          showToolbar = true
        }
    } else {
      ContentUnavailableView(
        "Nothing selected", systemImage: "doc.text",
        description: Text("Pick a page from the sidebar."))
    }
  }

  /// Decides whether the bar should be up, given the document's latest scroll
  /// offset. Three rules:
  ///
  /// - near the top the bar is always up, whichever way you're moving;
  /// - a *run* of downward scrolling longer than `hideAfter` hides it;
  /// - a shorter run back upward brings it back, so reaching for the toolbar
  ///   mid-document costs one flick rather than a scroll to the top.
  ///
  /// The run resets whenever direction flips, so what matters is continuous
  /// travel one way, not net travel since the document opened. Tracking net
  /// travel instead leaves a large positive balance after a long read down,
  /// so scrolling back up never crosses zero and the bar never returns.
  private func handleScroll(_ offset: CGFloat) {
    let topZone: CGFloat = 24
    let hideAfter: CGFloat = 32
    let showAfter: CGFloat = 12

    let delta = offset - scrollTracker.lastOffset
    scrollTracker.lastOffset = offset
    guard offset > topZone else {
      scrollTracker.run = 0
      if !showToolbar { showToolbar = true }
      return
    }
    // Momentum scrolling emits a long tail of sub-point deltas; ignoring them
    // keeps a settling scroll from nudging the run across a threshold.
    guard abs(delta) > 0.5 else { return }
    if delta.sign != scrollTracker.run.sign { scrollTracker.run = 0 }
    scrollTracker.run += delta

    if scrollTracker.run > hideAfter, showToolbar {
      showToolbar = false
    } else if scrollTracker.run < -showAfter, !showToolbar {
      showToolbar = true
    }
  }

  /// Floats over the top of the editor, its own bar rather than part of the
  /// window's native toolbar, so it (background included) can fade away as
  /// the doc scrolls beneath it. The native toolbar spans the sidebar too,
  /// and can't fade only over the detail column.
  ///
  /// Showing and hiding belong to `detail`, which inserts and removes this
  /// whole view with a slide-and-fade transition. It reads on screen the way
  /// an offset and an opacity would, and the document appears to scroll the
  /// bar off rather than dissolve it in place, but the material underneath
  /// stops costing anything once the bar is gone.
  private var docToolbar: some View {
    HStack(spacing: 16) {
      Button {
        // One transaction for both the split view's divider and this bar's
        // leading inset, so the bar slides with the sidebar instead of the
        // inset animating on its own while the bar's width jumps.
        withAnimation(Self.sidebarAnimation) {
          columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
      } label: {
        Image(systemName: "sidebar.leading")
      }
      .help("Hide or show the sidebar")
      VStack(alignment: .leading, spacing: 0) {
        Text(model.repo?.lastPathComponent ?? "RepoDocs")
          .font(.headline)
        if !model.status.isEmpty {
          Text(model.status)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .lineLimit(1)
      Spacer()
      Button {
        newPath = ""
        isNaming = true
      } label: {
        Image(systemName: "square.and.pencil")
      }
      .disabled(model.repo == nil)
      .help("New Page")
      Button {
        importFiles()
      } label: {
        Image(systemName: "square.and.arrow.down")
      }
      .disabled(model.repo == nil)
      .help("Import existing markdown files or folders from the repo")
      Button {
        model.showInspector.toggle()
      } label: {
        Image(systemName: "sidebar.trailing")
      }
      .help("Info")
      Button {
        Task { await model.save() }
      } label: {
        Image(systemName: "arrow.down.doc")
      }
      .keyboardShortcut("s")
      .disabled(!model.isDirty)
      .help("Save")
    }
    .buttonStyle(.borderless)
    .imageScale(.large)
    .padding(.trailing, 12)
    // Collapsing the sidebar slides this bar over to the window's left edge,
    // where the traffic lights are. Pad far enough to clear them; when the
    // sidebar is visible it covers that area instead.
    .padding(.leading, columnVisibility == .detailOnly ? 100 : 12)
    .animation(Self.sidebarAnimation, value: columnVisibility)
    .frame(height: Self.toolbarHeight)
    .background(.bar)
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

  private var newFolderSheet: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New folder").font(.headline)
      Text("A folder path, e.g. `design/proposals`. It isn't saved until a page is added inside it.")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("design/proposals", text: $newFolderPath)
        .textFieldStyle(.roundedBorder)
        .frame(width: 320)
        .onSubmit(createFolder)
      HStack {
        Spacer()
        Button("Cancel") { isNamingFolder = false }
          .keyboardShortcut(.cancelAction)
        Button("Create", action: createFolder)
          .keyboardShortcut(.defaultAction)
          .disabled(newFolderPath.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
  }

  private func createFolder() {
    let path = newFolderPath
    isNamingFolder = false
    model.createFolder(path: path)
  }

  /// Sidebar right-click menu, offered both on a row (pre-filled with that
  /// row's own folder, so items land alongside it) and on the list's empty
  /// area (`prefix` is `""`, i.e. the repo root).
  @ViewBuilder
  private func newItemMenu(in prefix: String) -> some View {
    Button("New Page…") {
      newPath = prefix
      isNaming = true
    }
    .disabled(model.repo == nil)
    Button("New Folder…") {
      newFolderPath = prefix
      isNamingFolder = true
    }
    .disabled(model.repo == nil)
  }

  /// Lets the user pick markdown files or folders already sitting in the
  /// repo's working tree (or anywhere else) and pull them into the page
  /// store. Defaults to browsing from the repo root since that's the common
  /// case: docs that predate this app and are still sitting in the tree.
  private func importFiles() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.prompt = "Import"
    panel.message = "Choose markdown files or folders to import as pages."
    panel.directoryURL = model.repo
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    Task { await model.importPaths(urls) }
  }

}

/// Scroll bookkeeping for `ContentView.handleScroll`. A reference type held in
/// `@State` so updating it on every scroll tick doesn't re-render the view;
/// only the `showToolbar` flag it feeds should do that.
@MainActor
private final class ScrollTracker {
  var lastOffset: CGFloat = 0
  /// Signed distance travelled in the current unbroken direction; positive is
  /// downward (into the document).
  var run: CGFloat = 0

  func reset() {
    lastOffset = 0
    run = 0
  }
}

/// Carries the focused editor's command channel up to the app's Format menu.
/// Written out longhand rather than with `@Entry`, which needs macOS 15; this
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
