// KeychronMapper — app de barra de menu.
//
// Enquanto um Keychron (ANSI, ex.: C1 Pro 8K QMK) estiver conectado, troca a fonte
// de entrada para "U.S. International – PC", para que cada tecla produza o que está
// impresso nela (acentos via teclas mortas: ' + c = ç). Ao desconectar, ou ao sair
// do app, volta para a fonte anterior. O teclado interno do Mac não é afetado.
//
// Também detecta quando o macOS cadastrou o Keychron como ISO em vez de ANSI
// (o que troca as teclas ` e §) e oferece a correção.

import AppKit
import Carbon
import IOKit
import ServiceManagement

enum Config {
    static let keychronVendorID = 0x3434
    static let targetInputSource = "com.apple.keylayout.USInternational-PC"
    static let fallbackInputSource = "com.apple.keylayout.Brazilian-Pro"
    static let ansiKeyboardType = 40
    static let keyboardTypePlist = "/Library/Preferences/com.apple.keyboardtype.plist"

    /// No modo Mac, o firmware QMK do Keychron envia comandos de sistema na linha F
    /// (que tiram o app do foco). Traduz de volta para F1–F12 comuns.
    /// Formato hidutil: (usage page << 32) | usage. F5/F6 controlam o RGB no próprio
    /// firmware e não chegam ao Mac.
    static let functionRowMapping: [(source: UInt64, destination: UInt64)] = {
        let consumer: UInt64 = 0x0C_0000_0000
        let appleKeyboard: UInt64 = 0xFF01_0000_0000
        let keyboard: UInt64 = 0x07_0000_0000
        let f = { (n: UInt64) in keyboard | (0x3A + n - 1) } // F1 = 0x3A … F12 = 0x45
        return [
            (consumer | 0x070, f(1)), // brilho −
            (consumer | 0x06F, f(2)), // brilho +
            (consumer | 0x29F, f(3)), // Mission Control
            (appleKeyboard | 0x10, f(3)), // Mission Control (página Apple)
            (consumer | 0x2A0, f(4)), // Launchpad
            (appleKeyboard | 0x04, f(4)), // Launchpad (página Apple)
            (consumer | 0x0B6, f(7)), // faixa anterior
            (consumer | 0x0CD, f(8)), // play/pause
            (consumer | 0x0B5, f(9)), // próxima faixa
            (consumer | 0x0E2, f(10)), // mudo
            (consumer | 0x0EA, f(11)), // volume −
            (consumer | 0x0E9, f(12)), // volume +
        ]
    }()
}

struct Keyboard: Hashable {
    let vendorID: Int
    let productID: Int
    let name: String

    var keyboardTypeKey: String { "\(productID)-\(vendorID)-0" }
}

// MARK: - Detecção do teclado (IOKit, não precisa de permissão de Monitoramento de Entrada)

final class KeyboardMonitor {
    var onChange: (([Keyboard]) -> Void)?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pendingRefresh: DispatchWorkItem?

    private func matchingDictionary() -> CFDictionary {
        let dict = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
        dict["IOPropertyMatch"] = [
            "VendorID": Config.keychronVendorID,
            "PrimaryUsagePage": 1, // Generic Desktop
            "PrimaryUsage": 6, // Keyboard
        ]
        return dict
    }

    func start() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context!).takeUnretainedValue()
            monitor.drain(iterator)
            monitor.scheduleRefresh()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, matchingDictionary(), callback, context, &iterator)
            drain(iterator) // arma a notificação
            iterators.append(iterator)
        }
        refresh()
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func refresh() {
        onChange?(connectedKeyboards())
    }

    func connectedKeyboards() -> [Keyboard] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary(), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var keyboards = Set<Keyboard>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if (property("Built-In") as? Bool) == true { continue }
            guard let vendor = property("VendorID") as? Int, let product = property("ProductID") as? Int else { continue }
            let name = property("Product") as? String ?? "Keychron"
            keyboards.insert(Keyboard(vendorID: vendor, productID: product, name: name))
        }
        return keyboards.sorted { $0.name < $1.name }
    }
}

// MARK: - Fonte de entrada

final class InputSourceSwitcher {
    private let savedKey = "previousInputSourceID"
    private let defaults = UserDefaults.standard

    /// Só existe enquanto o app trocou a fonte e ainda não restaurou.
    private var savedSourceID: String? {
        get { defaults.string(forKey: savedKey) }
        set { defaults.set(newValue, forKey: savedKey) }
    }

    var currentID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.id(of: source)
    }

    func activate() {
        guard let current = currentID, current != Config.targetInputSource else { return }
        if savedSourceID == nil { savedSourceID = current }
        Self.select(Config.targetInputSource)
    }

    func restore() {
        guard let previous = savedSourceID else { return }
        savedSourceID = nil
        // Se o usuário trocou de fonte manualmente enquanto o Keychron estava conectado, respeita.
        guard currentID == Config.targetInputSource else { return }
        if !Self.select(previous) { Self.select(Config.fallbackInputSource) }
    }

    @discardableResult
    private static func select(_ id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return false }
        TISEnableInputSource(source)
        return TISSelectInputSource(source) == noErr
    }

    private static func id(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

// MARK: - Remapeamento por dispositivo (hidutil; afeta só o Keychron)

enum KeyRemapper {
    static func apply(_ keyboard: Keyboard) {
        let entries = Config.functionRowMapping.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}"
        }
        set(keyboard, mapping: "[\(entries.joined(separator: ","))]")
    }

    static func clear(_ keyboard: Keyboard) {
        set(keyboard, mapping: "[]")
    }

    private static func set(_ keyboard: Keyboard, mapping: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = [
            "property",
            "--matching", "{\"VendorID\":\(keyboard.vendorID),\"ProductID\":\(keyboard.productID)}",
            "--set", "{\"UserKeyMapping\":\(mapping)}",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Tipo de teclado (ANSI × ISO)

enum KeyboardTypeFixer {
    static func needsFix(_ keyboard: Keyboard) -> Bool {
        let plist = NSDictionary(contentsOfFile: Config.keyboardTypePlist)
        let types = plist?["keyboardtype"] as? [String: Int] ?? [:]
        return types[keyboard.keyboardTypeKey] != Config.ansiKeyboardType
    }

    /// Grava ANSI no arquivo do sistema (pede senha de administrador).
    static func fix(_ keyboards: [Keyboard]) -> Bool {
        let commands = keyboards.map {
            "defaults write \(Config.keyboardTypePlist) keyboardtype -dict-add '\($0.keyboardTypeKey)' -int \(Config.ansiKeyboardType)"
        }.joined(separator: " && ")
        let source = "do shell script \"\(commands)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = KeyboardMonitor()
    private let switcher = InputSourceSwitcher()
    private var keyboards: [Keyboard] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.onChange = { [weak self] keyboards in self?.update(keyboards) }
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboards.forEach(KeyRemapper.clear)
        switcher.restore()
    }

    private func update(_ keyboards: [Keyboard]) {
        self.keyboards = keyboards
        if keyboards.isEmpty {
            switcher.restore()
        } else {
            switcher.activate()
            keyboards.forEach(KeyRemapper.apply)
            // Os serviços HID do teclado podem surgir um pouco depois do dispositivo.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.keyboards.forEach(KeyRemapper.apply)
            }
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let active = !keyboards.isEmpty
        statusItem.button?.image = NSImage(
            systemSymbolName: active ? "keyboard.fill" : "keyboard",
            accessibilityDescription: "KeychronMapper"
        )
        statusItem.button?.appearsDisabled = !active

        let menu = NSMenu()
        if active {
            for keyboard in keyboards {
                menu.addItem(disabledItem("✓ \(keyboard.name) conectado"))
            }
            menu.addItem(disabledItem("Layout: U.S. International – PC"))
            menu.addItem(disabledItem("F1–F12: teclas de função comuns"))
            if keyboards.contains(where: KeyboardTypeFixer.needsFix) {
                menu.addItem(.separator())
                menu.addItem(disabledItem("⚠︎ macOS trata o teclado como ISO"))
                menu.addItem(item("Corrigir para ANSI…", #selector(fixKeyboardType)))
            }
        } else {
            menu.addItem(disabledItem("Nenhum Keychron conectado"))
            menu.addItem(disabledItem("Remapeamento inativo"))
        }

        menu.addItem(.separator())
        let login = item("Abrir ao iniciar sessão", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Sair", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func fixKeyboardType() {
        guard KeyboardTypeFixer.fix(keyboards) else { return }
        let alert = NSAlert()
        alert.messageText = "Tipo de teclado corrigido para ANSI"
        alert.informativeText = "Desconecte e reconecte o Keychron para aplicar."
        alert.runModal()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
