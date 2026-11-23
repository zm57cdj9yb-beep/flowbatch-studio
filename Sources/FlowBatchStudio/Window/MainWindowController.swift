import AppKit
import FlowBatchCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Main document window controller managing the 3-pane `NSSplitViewController`, unified toolbar,
/// Play/Stop batch execution, file open/save, and `@MainActor UserPromptService` sheets.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, UserPromptService {
    let store: WorkflowStore
    let runner: PipelineRunner

    private let splitVC = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var centerItem: NSSplitViewItem!
    private var previewItem: NSSplitViewItem!

    private var canvasView: NodeGraphCanvasNSView!
    private var consoleHost: NSHostingView<WorkflowConsoleView>!
    private var consoleHeightConstraint: NSLayoutConstraint!
    private var isConsoleVisible = false

    private var statusCapsuleHost: NSHostingView<ToolbarStatusCapsuleView>!
    private var runTask: Task<Void, Never>?

    private enum ToolbarItemID {
        static let sidebar = NSToolbarItem.Identifier("fb.sidebar")
        static let title = NSToolbarItem.Identifier("fb.title")
        static let run = NSToolbarItem.Identifier("fb.run")
        static let status = NSToolbarItem.Identifier("fb.status")
        static let togglePreview = NSToolbarItem.Identifier("fb.preview")
        static let toggleInspector = NSToolbarItem.Identifier("fb.inspector")
        static let toggleConsole = NSToolbarItem.Identifier("fb.console")
        static let zoomFit = NSToolbarItem.Identifier("fb.zoomFit")
    }

    init(store: WorkflowStore = WorkflowStore(), runner: PipelineRunner = PipelineRunner()) {
        self.store = store
        self.runner = runner

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 960, height: 600)
        window.title = store.document.documentTitle
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.center()

        super.init(window: window)

        setupSplitLayout()
        setupToolbar()
        observeWindowState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        DispatchQueue.main.async { [weak self] in
            self?.canvasView.syncInspectorPopover()
        }
    }

    // MARK: - Split Layout

    private func setupSplitLayout() {
        let sidebarHost = NSHostingController(rootView: NodeLibrarySidebarView(store: store))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 185
        sidebarItem.maximumThickness = 270
        sidebarItem.canCollapse = true

        let centerContainer = NSViewController()
        let rootView = NSView()
        canvasView = NodeGraphCanvasNSView(store: store)
        consoleHost = NSHostingView(rootView: WorkflowConsoleView(store: store))

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        consoleHost.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(canvasView)
        rootView.addSubview(consoleHost)

        consoleHeightConstraint = consoleHost.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: rootView.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: consoleHost.topAnchor),

            consoleHost.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            consoleHost.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            consoleHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            consoleHeightConstraint
        ])
        centerContainer.view = rootView
        centerItem = NSSplitViewItem(viewController: centerContainer)
        centerItem.minimumThickness = 400

        let previewHost = NSHostingController(rootView: PreviewSplitPaneView(store: store, runner: runner))
        previewItem = NSSplitViewItem(viewController: previewHost)
        previewItem.minimumThickness = 280
        previewItem.maximumThickness = 600
        previewItem.canCollapse = true

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(centerItem)
        splitVC.addSplitViewItem(previewItem)
        splitVC.preferredContentSize = NSSize(width: 1320, height: 800)

        window?.contentViewController = splitVC
        window?.setContentSize(NSSize(width: 1320, height: 800))
        window?.center()
        DispatchQueue.main.async { [weak self] in
            self?.splitVC.splitView.setPosition(210, ofDividerAt: 0)
            self?.splitVC.splitView.setPosition(930, ofDividerAt: 1)
        }
    }

    // MARK: - Unified Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "FlowBatchMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemID.sidebar,
            ToolbarItemID.title,
            .flexibleSpace,
            ToolbarItemID.run,
            ToolbarItemID.status,
            .flexibleSpace,
            ToolbarItemID.togglePreview,
            ToolbarItemID.toggleConsole,
            ToolbarItemID.toggleInspector,
            ToolbarItemID.zoomFit
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier {
        case ToolbarItemID.sidebar:
            item.label = String(localized: "Sidebar")
            item.toolTip = String(localized: "Toggle Node Library")
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Node Library")
            item.target = self
            item.action = #selector(toggleSidebar(_:))

        case ToolbarItemID.title:
            let titleHost = NSHostingView(rootView: ToolbarDocumentTitleView(store: store))
            titleHost.frame = NSRect(x: 0, y: 0, width: 230, height: 24)
            item.view = titleHost

        case ToolbarItemID.run:
            item.label = String(localized: "Run")
            item.toolTip = String(localized: "Run or Stop Batch Workflow (⌘R)")
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run Workflow")
            item.target = self
            item.action = #selector(toggleRunWorkflow(_:))

        case ToolbarItemID.status:
            statusCapsuleHost = NSHostingView(rootView: ToolbarStatusCapsuleView(store: store))
            statusCapsuleHost.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            item.view = statusCapsuleHost

        case ToolbarItemID.togglePreview:
            item.label = String(localized: "Preview")
            item.toolTip = String(localized: "Toggle Preview & Asset Grid")
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Toggle Preview")
            item.target = self
            item.action = #selector(togglePreviewPane(_:))

        case ToolbarItemID.toggleConsole:
            item.label = String(localized: "Console")
            item.toolTip = String(localized: "Toggle Workflow Console")
            item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Toggle Console")
            item.target = self
            item.action = #selector(toggleConsoleDrawer(_:))

        case ToolbarItemID.toggleInspector:
            item.label = String(localized: "Inspector")
            item.toolTip = String(localized: "Show/Hide Selected Node Inspector")
            item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Toggle Inspector")
            item.target = self
            item.action = #selector(toggleInspectorPopover(_:))

        case ToolbarItemID.zoomFit:
            item.label = String(localized: "Zoom to Fit")
            item.toolTip = String(localized: "Fit Graph to Canvas")
            item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Zoom to Fit")
            item.target = self
            item.action = #selector(zoomToFit(_:))

        default:
            return nil
        }

        return item
    }

    private func observeWindowState() {
        withObservationTracking {
            _ = store.isRunning
            _ = store.document.documentTitle
            _ = store.hasUnsavedChanges
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.window?.title = self.store.document.documentTitle
                self.window?.isDocumentEdited = self.store.hasUnsavedChanges
                if let runItem = self.window?.toolbar?.items.first(where: { $0.itemIdentifier == ToolbarItemID.run }) {
                    runItem.image = NSImage(
                        systemSymbolName: self.store.isRunning ? "stop.fill" : "play.fill",
                        accessibilityDescription: self.store.isRunning ? "Stop" : "Run"
                    )
                }
                self.observeWindowState()
            }
        }
    }

    // MARK: - Actions

    @objc func toggleSidebar(_ sender: Any?) {
        sidebarItem.animator().isCollapsed.toggle()
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        previewItem.animator().isCollapsed.toggle()
    }

    @objc func toggleConsoleDrawer(_ sender: Any?) {
        isConsoleVisible.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            consoleHeightConstraint.animator().constant = isConsoleVisible ? 150 : 0
        }
    }

    @objc func toggleInspectorPopover(_ sender: Any?) {
        if store.inspectorVisibleNodeID != nil {
            store.inspectorVisibleNodeID = nil
        } else {
            store.inspectorVisibleNodeID = store.primarySelectedNodeID ?? store.document.nodes.first?.id
        }
        canvasView.syncInspectorPopover()
    }

    @objc func zoomToFit(_ sender: Any?) {
        canvasView.zoomToFit()
    }

    @objc func toggleRunWorkflow(_ sender: Any?) {
        if store.isRunning {
            runTask?.cancel()
            store.isRunning = false
            store.runStatusDetail = String(localized: "Cancelled")
            return
        }
        runWorkflow()
    }

    func runWorkflow() {
        store.clearRunLogs()
        store.isRunning = true
        store.runProgress = 0
        store.runStatusDetail = String(localized: "Preparing batch…")

        let docSnapshot = store.document
        let storeRef = store
        let runnerRef = runner
        let promptRef: any UserPromptService = self

        runTask = Task {
            do {
                let summary = try await runnerRef.runWorkflow(
                    document: docSnapshot,
                    promptService: promptRef,
                    progressHandler: { pct, msg in
                        Task { @MainActor in
                            storeRef.runProgress = pct
                            storeRef.runStatusDetail = msg
                        }
                    },
                    logHandler: { nodeID, nodeTitle, level, message in
                        Task { @MainActor in
                            storeRef.appendLog(ConsoleLogEntry(nodeID: nodeID, nodeTitle: nodeTitle, level: level, message: message))
                        }
                    }
                )
                await MainActor.run {
                    storeRef.isRunning = false
                    storeRef.runProgress = 1.0
                    storeRef.runStatusDetail = String(localized: "Exported \(summary.writtenFiles.count) file(s) in \(String(format: "%.2fs", summary.elapsedSeconds))")
                    if !summary.errors.isEmpty && !self.isConsoleVisible {
                        self.toggleConsoleDrawer(nil)
                    }
                }
            } catch {
                await MainActor.run {
                    storeRef.isRunning = false
                    storeRef.runStatusDetail = error.localizedDescription
                    storeRef.appendLog(ConsoleLogEntry(nodeTitle: "Workflow", level: .error, message: error.localizedDescription))
                    if !self.isConsoleVisible {
                        self.toggleConsoleDrawer(nil)
                    }
                }
            }
        }
    }

    // MARK: - File Commands

    @objc func newWorkflowDocument(_ sender: Any?) {
        store.undoManager.removeAllActions()
        store.document = WorkflowDocumentModel(documentTitle: "Untitled.flowbatch")
        store.fileURL = nil
        store.hasUnsavedChanges = false
        store.selectNode(nil)
        store.refreshDryRun()
    }

    @objc func openWorkflowDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.flowbatchWorkflow]
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                try self.store.load(from: url)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func saveWorkflowDocument(_ sender: Any?) {
        if let existing = store.fileURL {
            do {
                try store.save(to: existing)
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window) }
            }
        } else {
            saveWorkflowDocumentAs(sender)
        }
    }

    @objc func saveWorkflowDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.flowbatchWorkflow]
        panel.nameFieldStringValue = store.document.documentTitle
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                try self.store.save(to: url)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func undoAction(_ sender: Any?) {
        store.undoManager.undo()
    }

    @objc func redoAction(_ sender: Any?) {
        store.undoManager.redo()
    }

    // MARK: - UserPromptService ("Ask on Run" & Prompt for Files)

    func chooseFiles(allowMultiple: Bool) async -> [URL]? {
        guard let window else { return nil }
        return await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = allowMultiple
            panel.allowedContentTypes = [.image, .pdf]
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.urls : nil)
            }
        }
    }

    func chooseOutputFolder(promptTitle: String) async -> URL? {
        guard let window else { return nil }
        return await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.title = promptTitle
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

private struct ToolbarDocumentTitleView: View {
    @Bindable var store: WorkflowStore

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(store.document.documentTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if store.hasUnsavedChanges {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolbarStatusCapsuleView: View {
    @Bindable var store: WorkflowStore

    var body: some View {
        HStack(spacing: 7) {
            if store.isRunning {
                ProgressView(value: store.runProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 52)
                Text(store.runStatusDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Image(systemName: "photo.stack")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(store.runStatusDetail.isEmpty ? store.dryRun.statusText : store.runStatusDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3.5)
        .frame(width: 318)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
        )
    }
}
