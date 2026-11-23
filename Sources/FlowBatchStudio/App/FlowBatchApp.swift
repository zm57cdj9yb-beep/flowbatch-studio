import AppKit
import FlowBatchCore

@main
@MainActor
final class FlowBatchAppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = FlowBatchAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard let controller = mainWindowController else { return false }
        do {
            try controller.store.load(from: url)
            return true
        } catch {
            return false
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FlowBatch Studio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FlowBatch Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Workflow", action: #selector(MainWindowController.newWorkflowDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open Workflow…", action: #selector(MainWindowController.openWorkflowDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(MainWindowController.saveWorkflowDocument(_:)), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(MainWindowController.saveWorkflowDocumentAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit Menu (Undo / Redo wired to WorkflowStore.undoManager)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(MainWindowController.undoAction(_:)), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(MainWindowController.redoAction(_:)), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Workflow Menu
        let wfMenuItem = NSMenuItem()
        let wfMenu = NSMenu(title: "Workflow")
        wfMenu.addItem(withTitle: "Run / Stop Workflow", action: #selector(MainWindowController.toggleRunWorkflow(_:)), keyEquivalent: "r")
        wfMenu.addItem(withTitle: "Zoom to Fit", action: #selector(MainWindowController.zoomToFit(_:)), keyEquivalent: "0")
        wfMenuItem.submenu = wfMenu
        mainMenu.addItem(wfMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Node Library", action: #selector(MainWindowController.toggleSidebar(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Toggle Preview Pane", action: #selector(MainWindowController.togglePreviewPane(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Toggle Console", action: #selector(MainWindowController.toggleConsoleDrawer(_:)), keyEquivalent: "3")
        viewMenu.addItem(withTitle: "Toggle Node Inspector", action: #selector(MainWindowController.toggleInspectorPopover(_:)), keyEquivalent: "i")
        viewMenu.addItem(.separator())
        let fsItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fsItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fsItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
