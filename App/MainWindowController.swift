import AppKit
import SwiftUI

final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private static let minimumWindowWidth: CGFloat = 843

    unowned let appDelegate: AppDelegate

    init(owner: AppDelegate) {
        self.appDelegate = owner
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.window = window
        window.title = "RimWorld Utilities"
        window.center()
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.contentViewController = NSHostingController(
            rootView: RootView(model: appDelegate.appModel)
                .frame(minWidth: Self.minimumWindowWidth)
        )
        window.setFrameAutosaveName("MainWindow")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [AppDelegate.toggleSidebarToolbarItem, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [AppDelegate.toggleSidebarToolbarItem, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == AppDelegate.toggleSidebarToolbarItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = appDelegate.localized("Боковое меню", "Sidebar")
        item.paletteLabel = item.label
        item.toolTip = appDelegate.localized("Показать или скрыть боковое меню", "Show or hide the sidebar")
        item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: item.label)
        item.target = appDelegate
        item.action = #selector(AppDelegate.toggleSidebar)
        return item
    }
}
