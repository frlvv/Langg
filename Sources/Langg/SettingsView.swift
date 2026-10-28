import SwiftUI
import ServiceManagement
import AppKit
import UniformTypeIdentifiers

private enum SettingsSection: String, Hashable, CaseIterable {
    case general = "Основные"
    case shortcuts = "Горячие клавиши"
    case exclusions = "Исключения"
    case about = "О приложении"

    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .shortcuts: "keyboard"
        case .exclusions: "hand.raised.fill"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general: .blue
        case .shortcuts: .indigo
        case .exclusions: .orange
        case .about: .gray
        }
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: InputMonitor
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var recorder: ShortcutRecorder
    @ObservedObject private var updates = UpdateController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.undoManager) private var undoManager
    @State private var section: SettingsSection? = .general
    @State private var word = ""
    @State private var appError: String?
    @State private var wordError: String?
    @StateObject private var loginItem = LoginItemController()
    @StateObject private var permissions = PermissionManagement()
    @State private var confirmingPermissionRevocation = false
    @State private var applicationPanel: NSOpenPanel?
    @FocusState private var wordFocused: Bool

    init(monitor: InputMonitor) {
        self.monitor = monitor
        _settings = ObservedObject(wrappedValue: monitor.settings)
        _recorder = ObservedObject(wrappedValue: monitor.shortcutRecorder)
    }

    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.26, bounce: 0)
    }
    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4))
    }
    private var ready: Bool { monitor.status == "Работает" }
    private var correctionWarning: String? {
        switch monitor.correctionFeedback {
        case nil, "Текст исправлен.", "Исправление отменено.": nil
        case "Поле не подтвердило замену. Проверьте текст перед повторным исправлением.":
            "Не удалось проверить исправление. Проверьте текст перед повтором."
        case let message: message
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "character.cursor.ibeam")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Langg").font(.system(size: 20, weight: .semibold))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                List(SettingsSection.allCases, id: \.self, selection: $section) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityHidden(true)
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: (section ?? .general) == item ? .semibold : .regular))
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                    .tag(item)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 250)
        } detail: {
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch section ?? .general {
                        case .general: general
                        case .shortcuts: shortcuts
                        case .exclusions: exclusions
                        case .about: about
                        }
                    }
                    .font(.system(size: 13))
                    .background(alignment: .topLeading) {
                        OverlayScrollbars().frame(width: 0, height: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .id(section)
                .modifier(SettingsScrollEdge())
            }
            .background(colorScheme == .dark ? Color(white: 0.141) : Color(nsColor: .windowBackgroundColor))
            .toolbarBackground(.automatic, for: .windowToolbar)
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(id: "settingsTitle", placement: .navigation) { settingsTitle }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(id: "settingsTitle", placement: .navigation) { settingsTitle }
                }
            }
        }
        .onAppear {
            monitor.start()
            loginItem.refresh()
        }
        .onDisappear {
            recorder.stop()
            confirmingPermissionRevocation = false
            applicationPanel?.cancel(nil)
        }
        .onChange(of: section) { _, _ in
            recorder.stop()
            confirmingPermissionRevocation = false
            wordFocused = false
        }
        .onChange(of: word) { _, _ in wordError = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            monitor.start()
            loginItem.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            recorder.stop()
        }
    }

    private var settingsTitle: some View {
        Text((section ?? .general).rawValue)
            .font(.system(size: 20, weight: .semibold))
            .tracking(0.1)
            .frame(width: 220, alignment: .leading)
            .padding(.leading, 16)
            .offset(y: 0.5)
            .opacity(section == .about ? 0 : 1)
            .accessibilityHidden(section == .about)
            .transaction { $0.animation = nil }
            .accessibilityAddTraits(.isHeader)
    }

    private var general: some View {
        Group {
            SettingsBlock {
                HStack(spacing: 14) {
                    Image(systemName: ready ? "checkmark.circle.fill"
                          : monitor.needsPermission ? "hand.raised.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(ready ? Color.green : monitor.needsPermission ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                    SettingLabel(ready ? "Готов к работе" : monitor.needsPermission ? "Нужен доступ" : "Подготовка к работе",
                                 subtitle: ready
                                    ? (settings.automatic ? "Автоисправление включено" : "Исправление по горячей клавише")
                                    : monitor.needsPermission ? "Разрешите Langg исправлять текст в приложениях." : nil)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .accessibilityElement(children: .combine)
                if let correctionWarning {
                    Label(correctionWarning, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                        .transition(.opacity)
                }
                if !monitor.keyboardAccessVerified {
                    rowDivider
                    permissionRows.padding(16)
                }
            }
            SettingsBlock("Исправление") {
                settingToggle("Автоисправление", subtitle: "Исправлять раскладку после завершения слова.",
                              isOn: $settings.automatic)
                rowDivider
                settingToggle("Уведомления у курсора", subtitle: "Показывать, что текст исправлен.",
                              isOn: $settings.notifications)
            }
            menuBarAppearance
            SettingsBlock {
                settingToggle("Запускать при входе", isOn: Binding(
                    get: { loginItem.isRegistered }, set: loginItem.setEnabled))
                if loginItem.needsApproval {
                    HStack {
                        Text("Подтвердите запуск в настройках macOS.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Открыть…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .padding([.horizontal, .bottom], 16)
                }
                if let error = loginItem.error { InlineError(error).padding([.horizontal, .bottom], 16) }
            }
            SettingsBlock("Разрешения") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        SettingLabel("Доступ к вводу", subtitle: "Управляйте доступом Langg в настройках macOS.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 6) {
                            if confirmingPermissionRevocation {
                                Button("Отозвать", role: .destructive) {
                                    withAnimation(motion) { confirmingPermissionRevocation = false }
                                    Task {
                                        if await permissions.revoke() {
                                            monitor.permissionsWereRevoked()
                                        }
                                    }
                                }
                                .help("Автоисправление и горячие клавиши перестанут работать до повторного разрешения доступа")
                                Button("Отмена") {
                                    withAnimation(motion) { confirmingPermissionRevocation = false }
                                }
                                .keyboardShortcut(.cancelAction)
                                .transition(.opacity)
                            } else {
                                Button(permissions.isRevoking ? "Отзыв разрешений…" : "Отозвать разрешения") {
                                    withAnimation(motion) { confirmingPermissionRevocation = true }
                                }
                                .transition(.opacity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(permissions.isRevoking)
                        .fixedSize()
                        .animation(motion, value: confirmingPermissionRevocation)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { permissionSettingsLinks }
                        VStack(alignment: .leading, spacing: 12) { permissionSettingsLinks }
                    }
                    if let message = permissions.message {
                        Text(message)
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
        }
        .toggleStyle(.switch)
    }

    private var permissionSettingsLinks: some View {
        Group {
            permissionSettingsLink("Универсальный доступ", permission: .accessibility,
                                   action: permissions.openAccessibility)
            permissionSettingsLink("Мониторинг ввода", permission: .inputMonitoring,
                                   action: permissions.openInputMonitoring)
        }
    }

    private func permissionSettingsLink(_ title: String, permission: InputPermission,
                                        action: @escaping () -> Void) -> some View {
        let granted = monitor.permissionStatus(for: permission) == .verified
        return Button(action: action) {
            HStack(spacing: 6) {
                if granted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(granted ? Color.green : Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(granted ? "Разрешено" : "Не подтверждено")
        .accessibilityHint("Открыть раздел в настройках macOS")
        .help("Открыть \(title.lowercased()) в настройках macOS")
    }

    private var permissionRows: some View {
        VStack(spacing: 14) {
            permissionRow("Универсальный доступ", status: monitor.permissionStatus(for: .accessibility)) {
                monitor.requestAccessibilityPermission()
            }
            permissionRow("Мониторинг ввода", status: monitor.permissionStatus(for: .inputMonitoring)) {
                monitor.requestInputMonitoringPermission()
            }
            if monitor.shouldOfferPermissionRestart {
                DisclosureGroup("Доступ всё ещё не работает?") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("После включения мониторинга ввода macOS обычно предлагает завершить и снова открыть Langg. Если этого не произошло, можно перезапустить приложение здесь.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button(permissions.isRestarting ? "Перезапуск…" : "Перезапустить Langg") {
                            Task { await permissions.restart() }
                        }
                        .buttonStyle(.link)
                        .disabled(permissions.isRestarting)
                    }
                    .padding(.top, 6)
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            if let applicationURL = permissions.applicationURL,
               InputPermission.allCases.contains(where: { monitor.permissionStatus(for: $0) == .awaitingVerification }) {
                DisclosureGroup("Если Langg не появился в списке") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Перетащите Langg из Finder в список разрешений в настройках macOS.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Показать Langg в Finder", action: permissions.showApplicationInFinder)
                            .buttonStyle(.link)
                        Text(applicationURL.path)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 6)
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var menuBarAppearance: some View {
        SettingsBlock {
            HStack(alignment: .top, spacing: 16) {
                Text("Значок в строке меню")
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 12) {
                    menuBarOption(.appIcon, title: "Логотип Langg") {
                        Image(nsImage: LanggMark.menuImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                    menuBarOption(.inputSource, title: "Текущая раскладка") {
                        HStack(spacing: 8) {
                            Image(nsImage: MenuBarSymbols.preview(for: "РУ", primaryLanguage: settings.primaryMenuBarLanguage))
                            Image(nsImage: MenuBarSymbols.preview(for: "A", primaryLanguage: settings.primaryMenuBarLanguage))
                        }
                    }
                }
            }
            .padding(16)
            if settings.menuBarIconStyle == .inputSource {
                rowDivider
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Основной язык")
                        Spacer(minLength: 16)
                        Picker("Основной язык", selection: $settings.primaryMenuBarLanguage) {
                            Text("Русский").tag(MenuBarPrimaryLanguage.russian)
                            Text("Английский").tag(MenuBarPrimaryLanguage.english)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140, alignment: .trailing)
                        .help("Основной язык выделяется заливкой значка. Раскладка клавиатуры не меняется.")
                        .accessibilityHint("Определяет заливку значка. Не переключает раскладку клавиатуры.")
                    }
                    Text("Чтобы убрать второй индикатор, откройте [«Клавиатура»](x-apple.systempreferences:com.apple.Keyboard-Settings.extension) → «Ввод текста» → «Изменить» и выключите «Показывать меню ввода в строке меню».")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Открыть настройки клавиатуры. В разделе «Ввод текста» нажмите «Изменить» и выключите «Показывать меню ввода в строке меню».")
                        .accessibilityHint("Открывает настройки клавиатуры macOS. Системный индикатор нужно выключить вручную.")
                }
                .padding(16)
            }
        }
    }

    private func menuBarOption<Preview: View>(_ style: MenuBarIconStyle, title: String,
                                               @ViewBuilder preview: () -> Preview) -> some View {
        let selected = settings.menuBarIconStyle == style
        return Button {
            settings.menuBarIconStyle = style
        } label: {
            VStack(spacing: 6) {
                preview()
                    .foregroundStyle(.primary)
                    .frame(width: style == .appIcon ? 64 : 92, height: 38)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func permissionRow(_ title: String, status: PermissionSetupStatus, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            if status == .verified {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).accessibilityLabel("Разрешено")
            } else {
                if status == .awaitingVerification {
                    Text("Ожидает проверки")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(status == .needsPermission ? "Разрешить" : "Открыть настройки…", action: action)
                    .accessibilityLabel(status == .needsPermission ? "Разрешить \(title.lowercased())" : "Открыть \(title.lowercased())")
            }
        }
    }

    private func settingToggle(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            SettingLabel(title, subtitle: subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn).labelsHidden()
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityHint(subtitle ?? "")
        }
        .padding(16)
    }

    private var shortcuts: some View {
        Group {
            PageIntro("Нажмите на сочетание, чтобы изменить его.")
            SettingsBlock {
                shortcutRow("Исправить текст", subtitle: "Выделение или последнее слово", command: .correction)
                rowDivider
                shortcutRow("Переключить раскладку", subtitle: "Русская ↔ английская", command: .switchLayout)
                rowDivider
                shortcutRow("Отменить исправление", subtitle: "Вернуть исходный текст", command: .undo)
                settingToggle("Возвращать раскладку при отмене исправления",
                              isOn: $settings.undoRestoresLayout)
            }
            if let shortcutError = recorder.error { InlineError(shortcutError).transition(.opacity) }
        }
    }

    private func shortcutRow(_ title: String, subtitle: String, command: ShortcutCommand) -> some View {
        let recording = recorder.command == command
        return HStack(spacing: 16) {
            SettingLabel(title, subtitle: subtitle)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button {
                    if recording { recorder.stop() }
                    else { recorder.start(command) }
                } label: {
                    Text(recording ? "Нажмите клавиши…" : shortcutLabel(settings.shortcut(for: command)))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(ShortcutButtonStyle(recording: recording))
                .accessibilityLabel(title)
                .accessibilityValue(recording ? "Запись сочетания" : settings.shortcut(for: command).title)
                .help(recording ? "Esc – отменить" : "Изменить сочетание. Клавиши показаны в английской раскладке и работают в обеих.")
                if recording {
                    Button { recorder.stop() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Отменить запись").accessibilityLabel("Отменить запись")
                    .transition(.opacity)
                }
            }
            .frame(width: 168)
            .animation(motion, value: recording)
        }
        .padding(16)
    }

    private var exclusions: some View {
        Group {
            PageIntro("Здесь раскладка меняется только по горячей клавише.")
            SettingsBlock("Приложения") {
                if settings.excludedApps.isEmpty { EmptyRow("Нет исключений", symbol: "app.dashed") }
                ForEach(settings.excludedApps, id: \.self) { id in
                    HStack(spacing: 12) {
                        appIcon(for: id)
                        Text(appName(for: id)).fontWeight(.medium)
                        Spacer(minLength: 8)
                        removeButton("Удалить \(appName(for: id)) из исключений") { removeApp(id) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .transition(rowTransition)
                    rowDivider
                }
                HStack {
                    Button { chooseApplication() } label: {
                        Label("Добавить приложение…", systemImage: "plus")
                    }
                    .disabled(applicationPanel != nil)
                    Spacer()
                }
                .padding(14)
                if let appError { InlineError(appError).padding([.horizontal, .bottom], 16) }
            }
            .animation(reduceMotion ? nil : motion, value: settings.excludedApps)
            SettingsBlock("Слова") {
                HStack(spacing: 10) {
                    TextField("Добавить слово", text: $word)
                        .textFieldStyle(.plain).focused($wordFocused)
                        .onSubmit(addWord).accessibilityLabel("Слово для исключения")
                    Button("Добавить", action: addWord)
                        .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(14)
                if let wordError {
                    InlineError(wordError).padding([.horizontal, .bottom], 16).transition(.opacity)
                }
                rowDivider
                if settings.excludedWords.isEmpty {
                    EmptyRow("Нет исключений", symbol: "text.badge.checkmark").transition(.opacity)
                } else {
                    ForEach(settings.excludedWords, id: \.self) { item in
                        HStack {
                            Text(item)
                            Spacer()
                            removeButton("Удалить слово \(item) из исключений") { removeWord(item) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .transition(rowTransition)
                        if item != settings.excludedWords.last { rowDivider }
                    }
                }
            }
            .animation(reduceMotion ? nil : motion, value: settings.excludedWords)
        }
    }

    private func shortcutLabel(_ shortcut: Shortcut) -> String {
        let keySymbols: [Int64: String] = [
            36: "↩", 48: "⇥", 51: "⌫", 76: "⌤", 117: "⌦",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟"
        ]
        guard let symbol = keySymbols[shortcut.keyCode] else { return shortcut.title }
        return String(shortcut.title.dropLast(shortcut.keyName.count)) + symbol
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").font(.system(size: 16))
                .foregroundStyle(.secondary).frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).accessibilityLabel(label).help("Удалить из исключений")
    }

    private func chooseApplication() {
        guard applicationPanel == nil else { return }
        recorder.stop()
        appError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Добавить"
        panel.message = "Выберите приложение для исключения."
        applicationPanel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            defer { applicationPanel = nil }
            guard response == .OK, let url = panel.url,
                  let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            guard !settings.excludedApps.contains(bundleID) else {
                appError = "Это приложение уже в исключениях."
                return
            }
            settings.excludedApps.append(bundleID)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func addWord() {
        let value = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard value.split(whereSeparator: \.isWhitespace).count == 1 else {
            wordError = "Добавляйте слова по одному."
            return
        }
        guard !settings.excludedWords.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            wordError = "Это слово уже в исключениях."
            return
        }
        settings.excludedWords.append(value)
        word = ""
        wordError = nil
        wordFocused = true
    }

    private func removeWord(_ value: String) {
        guard let index = settings.excludedWords.firstIndex(of: value) else { return }
        wordFocused = false
        wordError = nil
        settings.excludedWords.remove(at: index)
        undoManager?.registerUndo(withTarget: settings) { target in
            guard !target.excludedWords.contains(value) else { return }
            target.excludedWords.insert(value, at: min(index, target.excludedWords.count))
        }
        undoManager?.setActionName("Удаление слова")
    }

    private func removeApp(_ id: String) {
        guard let index = settings.excludedApps.firstIndex(of: id) else { return }
        wordFocused = false
        appError = nil
        settings.excludedApps.remove(at: index)
        undoManager?.registerUndo(withTarget: settings) { target in
            guard !target.excludedApps.contains(id) else { return }
            target.excludedApps.insert(id, at: min(index, target.excludedApps.count))
        }
        undoManager?.setActionName("Удаление приложения")
    }

    private func appName(for id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           let bundle = Bundle(url: url) {
            return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        let knownNames = ["com.apple.Terminal": "Терминал", "com.googlecode.iterm2": "iTerm"]
        return knownNames[id] ?? id.split(separator: ".").last.map { String($0).capitalized } ?? "Приложение"
    }

    @ViewBuilder private func appIcon(for id: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 28, height: 28).accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 22, weight: .light))
                .frame(width: 28, height: 28).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private var about: some View {
        VStack(spacing: 20) {
            LanggAboutMark()
            VStack(spacing: 6) {
                Text("Langg").font(.system(size: 28, weight: .semibold))
                Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Исправляет слова, набранные в другой раскладке.")
                .font(.body).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Русская и английская раскладки")
                Text("Текст остаётся на вашем Mac")
            }
            .font(.subheadline).foregroundStyle(.secondary)
            SettingsBlock("Обновления") {
                HStack(spacing: 16) {
                    SettingLabel("Проверять автоматически", subtitle: "Langg сообщит, когда появится новая версия.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Проверять автоматически", isOn: Binding(
                        get: { updates.automaticChecks }, set: updates.setAutomaticChecks))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!updates.isStarted)
                }
                .padding(16)
                rowDivider
                HStack {
                    Button("Проверить обновления…", action: updates.checkForUpdates)
                        .disabled(!updates.canCheckForUpdates)
                    Spacer()
                }
                .padding(16)
                if let message = updates.configurationMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding([.horizontal, .bottom], 16)
                }
            }
            Text("© 2026 Langg").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 12)
    }

    private var rowDivider: some View { Divider().padding(.horizontal, 16) }
}

private struct PageIntro: View {
    let subtitle: String
    init(_ subtitle: String) { self.subtitle = subtitle }

    var body: some View {
        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingLabel: View {
    let title: String
    var subtitle: String?
    init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13))
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsBlock<Content: View>: View {
    var title: String?
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 10).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colorScheme == .dark
                            ? Color(white: contrast == .increased ? 0.235 : 0.173)
                            : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(0.45))
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

private struct InlineError: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.subheadline).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
}

private struct EmptyRow: View {
    let title: String
    let symbol: String
    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View {
        Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}

private struct SettingsScrollEdge: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else { content }
    }
}

private struct ShortcutButtonStyle: ButtonStyle {
    let recording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(recording ? Color.accentColor : Color.primary)
            .background(recording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(contrast == .increased ? 0.5 : 0.12))
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
