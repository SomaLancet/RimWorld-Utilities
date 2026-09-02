import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppMenu {
    unowned let owner: AppDelegate

    init(owner: AppDelegate) {
        self.owner = owner
    }

    private func localized(_ russian: String, _ english: String) -> String { owner.localized(russian, english) }
    private func title(for page: UtilityPage) -> String { owner.title(for: page) }

    func build() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "RimWorld Utilities", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let aboutMenuItem = appMenu.addItem(withTitle: localized("О RimWorld Utilities", "About RimWorld Utilities"), action: #selector(AppDelegate.openAbout), keyEquivalent: "")
        aboutMenuItem.target = owner
        appMenu.addItem(.separator())
        let settingsMenuItem = appMenu.addItem(withTitle: localized("Настройки…", "Settings…"), action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settingsMenuItem.target = owner
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: localized("Службы", "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: localized("Службы", "Services"))
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: localized("Скрыть RimWorld Utilities", "Hide RimWorld Utilities"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: localized("Скрыть остальные", "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: localized("Показать все", "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: localized("Выйти", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(title: localized("Файл", "File"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: localized("Файл", "File"))
        addMenuItem(fileMenu, title: localized("Выбрать папку сохранений…", "Choose Saves Folder…"), action: #selector(AppDelegate.chooseSave), key: "o")
        addMenuItem(fileMenu, title: localized("Выбрать папку локальных модов…", "Choose Local Mods Folder…"), action: #selector(AppDelegate.chooseLocalModsDirectory))
        addMenuItem(fileMenu, title: localized("Выбрать папку Steam Workshop…", "Choose Steam Workshop Folder…"), action: #selector(AppDelegate.chooseWorkshopModsDirectory))
        fileMenu.addItem(.separator())
        addMenuItem(fileMenu, title: localized("Выбрать ModsConfig.xml…", "Choose ModsConfig.xml…"), action: #selector(AppDelegate.chooseConfig))
        addMenuItem(fileMenu, title: localized("Выбрать Player.log…", "Choose Player.log…"), action: #selector(AppDelegate.chooseLog))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: localized("Закрыть окно", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem(title: localized("Правка", "Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: localized("Правка", "Edit"))
        editMenu.addItem(withTitle: localized("Отменить", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: localized("Повторить", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: localized("Вырезать", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: localized("Копировать", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: localized("Вставить", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: localized("Удалить", "Delete"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: localized("Выбрать всё", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem(title: localized("Вид", "View"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: localized("Вид", "View"))
        let sidebarMenuItem = viewMenu.addItem(
            withTitle: localized("Показать или скрыть боковое меню", "Show or Hide Sidebar"),
            action: #selector(AppDelegate.toggleSidebar),
            keyEquivalent: "s"
        )
        sidebarMenuItem.target = owner
        sidebarMenuItem.keyEquivalentModifierMask = [.control, .command]
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let utilitiesItem = NSMenuItem(title: localized("Утилиты", "Utilities"), action: nil, keyEquivalent: "")
        let utilitiesMenu = NSMenu(title: localized("Утилиты", "Utilities"))
        addMenuItem(utilitiesMenu, title: title(for: .translation), action: #selector(AppDelegate.openTranslation), key: "1")
        addMenuItem(utilitiesMenu, title: title(for: .rjw), action: #selector(AppDelegate.openRJW), key: "2")
        addMenuItem(utilitiesMenu, title: title(for: .diagnostics), action: #selector(AppDelegate.openDiagnostics), key: "3")
        addMenuItem(utilitiesMenu, title: title(for: .modRemoval), action: #selector(AppDelegate.openModRemoval), key: "4")
        utilitiesMenu.addItem(.separator())
        addMenuItem(utilitiesMenu, title: localized("Обновить перевод", "Update Translation"), action: #selector(AppDelegate.updateTranslation), key: "u")
        addMenuItem(utilitiesMenu, title: localized("Применить выбор RJW", "Apply RJW Selection"), action: #selector(AppDelegate.applyRJWSelection), key: "j")
        addMenuItem(utilitiesMenu, title: localized("Запустить диагностику", "Run Diagnostics"), action: #selector(AppDelegate.analyze), key: "r")
        utilitiesMenu.addItem(.separator())
        addMenuItem(utilitiesMenu, title: localized("Проверить обновления…", "Check for Updates…"), action: #selector(AppDelegate.checkForUpdates))
        utilitiesItem.submenu = utilitiesMenu
        mainMenu.addItem(utilitiesItem)

        let windowItem = NSMenuItem(title: localized("Окно", "Window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: localized("Окно", "Window"))
        windowMenu.addItem(withTitle: localized("Свернуть", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: localized("Масштабировать", "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: localized("На передний план", "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem(title: localized("Справка", "Help"), action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: localized("Справка", "Help"))
        addMenuItem(helpMenu, title: localized("Репозиторий RimWorld Utilities", "RimWorld Utilities Repository"), action: #selector(AppDelegate.openApplicationRepository))
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    func addMenuItem(
        _ menu: NSMenu,
        title: String,
        action: Selector,
        key: String = ""
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = owner
        return item
    }


}
