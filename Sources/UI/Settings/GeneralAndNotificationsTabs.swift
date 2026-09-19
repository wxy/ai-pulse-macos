import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - General

struct GeneralTab: View {
    @Binding var lang: String
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var demoActive = DemoData.isActive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(I18n.t("general.title")).font(.title3).fontWeight(.semibold)
                Text(I18n.t("general.desc")).font(.caption).foregroundColor(.secondary)

                settingsGroup(I18n.t("general.group_general")) {
                    HStack {
                        Text(I18n.t("general.language_label"))
                            .frame(width: 140, alignment: .leading)
                        Picker("", selection: $lang) {
                            ForEach(I18n.supportedLanguages, id: \.code) { language in
                                if language.code == "auto" {
                                    Text(I18n.t("settings.language_auto")).tag("auto")
                                } else {
                                    Text(language.label).tag(language.code)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                        Spacer()
                    }
                }

                settingsGroup(SetupCopy.text("启动与引导", "Startup & onboarding")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(I18n.t("general.launch_at_login")).font(.body)
                            Text(I18n.t("general.launch_at_login_desc"))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .onChange(of: launchAtLogin) { _, enabled in
                                do {
                                    if enabled {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }

                    Divider()

                    if ProcessInfo.processInfo.arguments.contains("--show-demo-controls") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(demoActive ? I18n.t("demo.exit") : I18n.t("demo.enter"))
                                .font(.body)
                            Text(I18n.t("demo.onboarding_msg"))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(demoActive ? I18n.t("demo.exit") : I18n.t("demo.enter")) {
                            if DemoData.isActive {
                                DemoData.isManual = false
                                DemoData.isSuppressed = true
                            } else {
                                DemoData.isSuppressed = false
                                DemoData.isManual = true
                            }
                            NotificationCenter.default.post(name: .demoModeDidChange, object: nil)
                            NotificationCenter.default.post(name: .dataDidChange, object: nil)
                        }
                    }

                    Divider()

                    }

                    Text(SetupCopy.text("重新检查目录授权和工具状态，沿用已有配置与历史记录。", "Review folder access and tool status while retaining existing configuration and history."))
                        .font(.caption).foregroundColor(.secondary)
                    Button(I18n.t("general.rerun_welcome")) {
                        UserDefaults.standard.removeObject(forKey: "onboarding_completed")
                        if let window = OnboardingWindowManager.shared.window { window.close() }
                        let window = NSWindow(
                            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
                        window.title = I18n.t("onboarding.window_title")
                        window.contentView = NSHostingView(rootView: OnboardingView())
                        window.center()
                        window.makeKeyAndOrderFront(nil)
                        window.isReleasedWhenClosed = false
                        OnboardingWindowManager.shared.window = window
                    }
                }
            }
            .padding(.trailing, 16)
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoModeDidChange)) { _ in
            demoActive = DemoData.isActive
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SettingsCard(title: title, content: content)
    }
}

// MARK: - Notifications

struct NotificationsTab: View {
    @State private var soundMuted = AppSoundControl.isMuted()
    @State private var pulseSoundsEnabled = UserDefaults.standard.bool(forKey: "coin_sound_enabled")
    @State private var soundVolume =
        UserDefaults.standard.object(forKey: "sound_volume") as? Int ?? 50
    @State private var soundPack = {
        let raw = UserDefaults.standard.string(forKey: "sound_pack") ?? "coin"
        return raw == "default" ? "coin" : raw
    }()
    @State private var quietHoursEnabled =
        UserDefaults.standard.object(forKey: "sound_quiet_enabled") as? Bool ?? true
    @State private var quietFrom = UserDefaults.standard.string(forKey: "sound_quiet_from") ?? "22:00"
    @State private var quietTo = UserDefaults.standard.string(forKey: "sound_quiet_to") ?? "08:00"
    @State private var maxSoundsPerHour =
        UserDefaults.standard.object(forKey: "sound_max_per_hour") as? Int ?? 8
    @State private var startupChimeEnabled =
        UserDefaults.standard.object(forKey: "startup_chime_enabled") as? Bool ?? false
    @State private var closingBellEnabled =
        UserDefaults.standard.object(forKey: "closing_bell_enabled") as? Bool ?? true
    @State private var spendAlertsEnabled = SpendAlertSettings.current().master
    @State private var systemNotificationsEnabled = SystemNotifications.isEnabled
    @State private var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(I18n.t("general.group_notifications")).font(.title3).fontWeight(.semibold)
                Text(I18n.t("notifications.desc")).font(.caption).foregroundColor(.secondary)

                settingsGroup(I18n.t("notifications.group_system")) {
                    settingToggle(
                        title: I18n.t("general.system_notifications"),
                        description: I18n.t("general.system_notifications_desc"),
                        isOn: $systemNotificationsEnabled
                    )
                    .onChange(of: systemNotificationsEnabled) { _, enabled in
                        SystemNotifications.setEnabled(enabled)
                        if enabled { requestNotificationAuthorizationIfNeeded() }
                    }

                    Divider()

                    settingToggle(
                        title: I18n.t("general.spend_alerts"),
                        description: I18n.t("general.spend_alerts_desc"),
                        isOn: $spendAlertsEnabled
                    )
                    .disabled(!systemNotificationsEnabled)
                    .opacity(systemNotificationsEnabled ? 1 : 0.55)
                    .onChange(of: spendAlertsEnabled) { _, enabled in
                        UserDefaults.standard.set(enabled, forKey: SpendAlertSettings.masterKey)
                    }

                    Divider()
                    notificationPermissionRow
                }

                soundPreferences
            }
            .padding(.trailing, 16)
        }
        .onAppear { refreshNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: .soundMuteDidChange)) { _ in
            soundMuted = AppSoundControl.isMuted()
        }
    }

    private var soundPackSettings: some View {
        settingsGroup(I18n.t("perception.sound_pack")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(I18n.t("perception.sound_pack")).font(.body)
                    Spacer()
                    Picker("", selection: $soundPack) {
                        Text(I18n.t("perception.pack_coin")).tag("coin")
                        Text(I18n.t("perception.pack_droplet")).tag("droplet")
                        Text(I18n.t("perception.pack_register")).tag("register")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .onChange(of: soundPack) { _, pack in
                        UserDefaults.standard.set(pack, forKey: "sound_pack")
                    }
                }

                HStack {
                    Text(I18n.t("perception.volume")).font(.body)
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { Double(soundVolume) },
                            set: { value in
                                soundVolume = Int(value.rounded())
                                UserDefaults.standard.set(soundVolume, forKey: "sound_volume")
                            }), in: 0...100)
                    Text(verbatim: I18n.percent(Double(soundVolume) / 100))
                        .font(.caption).foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Divider()
            HStack(spacing: 8) {
                previewButton(I18n.t("perception.cue_activity"), decision: .coin)
                previewButton(I18n.t("perception.cue_elevated"), decision: .coinRain)
                previewButton(I18n.t("perception.cue_chime"), decision: .chime)
            }
        }
    }

    private var soundPreferences: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsGroup(I18n.t("notifications.group_sound_master")) {
                settingToggle(
                    title: I18n.t("perception.mute_all"),
                    description: I18n.t("perception.mute_all_desc"),
                    isOn: $soundMuted
                )
                .onChange(of: soundMuted) { _, muted in
                    AppSoundControl.setMuted(muted)
                }

                Divider()

                HStack {
                    Text(I18n.t("perception.quiet_hours")).font(.body)
                    Spacer()
                    HStack {
                        TextField("22:00", text: $quietFrom)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                        Text("–").foregroundColor(.secondary)
                        TextField("08:00", text: $quietTo)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                    .disabled(!quietHoursEnabled)
                    .onChange(of: quietFrom) { _, value in
                        UserDefaults.standard.set(value, forKey: "sound_quiet_from")
                    }
                    .onChange(of: quietTo) { _, value in
                        UserDefaults.standard.set(value, forKey: "sound_quiet_to")
                    }
                    Toggle("", isOn: $quietHoursEnabled)
                        .toggleStyle(.switch)
                        .accessibilityLabel(I18n.t("perception.quiet_hours"))
                        .onChange(of: quietHoursEnabled) { _, enabled in
                            UserDefaults.standard.set(enabled, forKey: "sound_quiet_enabled")
                        }
                }

            }

            soundPackSettings

            settingsGroup(I18n.t("notifications.group_sounds")) {
                settingToggle(
                    title: I18n.t("general.coin_sound"),
                    description: I18n.t("general.coin_sound_desc"),
                    isOn: $pulseSoundsEnabled
                )
                .onChange(of: pulseSoundsEnabled) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: "coin_sound_enabled")
                }
                HStack {
                    Text(I18n.t("perception.max_per_hour"))
                        .font(.caption)
                    Spacer()
                    Text("\(maxSoundsPerHour)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("", value: $maxSoundsPerHour, in: 1...30)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel(I18n.t("perception.max_per_hour"))
                        .disabled(!pulseSoundsEnabled)
                        .onChange(of: maxSoundsPerHour) { _, value in
                            UserDefaults.standard.set(value, forKey: "sound_max_per_hour")
                        }
                }

                Divider()

                settingToggle(
                    title: I18n.t("perception.closing_bell"),
                    description: I18n.t("perception.closing_bell_desc"),
                    isOn: $closingBellEnabled
                )
                .onChange(of: closingBellEnabled) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: "closing_bell_enabled")
                }

                Divider()

                settingToggle(
                    title: I18n.t("perception.startup_chime"),
                    description: I18n.t("perception.startup_chime_desc"),
                    isOn: $startupChimeEnabled
                )
                .onChange(of: startupChimeEnabled) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: "startup_chime_enabled")
                }
            }
        }
    }

    private func settingToggle(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(description).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch)
        }
    }

    private func previewButton(_ title: String, decision: SoundDecision) -> some View {
        Button {
            var settings = SoundSettings.current()
            // Preview is deliberate: ignore automatic cue toggles and quiet hours.
            // The global mute remains authoritative.
            settings.enabled = true
            settings.pack = soundPack
            CoinSound.playDecision(decision, settings: settings, isPreview: true)
        } label: {
            Label(title, systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(soundMuted)
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SettingsCard(title: title, content: content)
    }

    private var notificationPermissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: notificationPermissionIcon)
                .foregroundColor(notificationPermissionColor)
            Text(notificationPermissionText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button(I18n.t("general.open_notification_settings")) {
                guard
                    let url = URL(
                        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var notificationPermissionIcon: String {
        switch notificationAuthorization {
        case .authorized, .provisional, .ephemeral: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var notificationPermissionColor: Color {
        switch notificationAuthorization {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private var notificationPermissionText: String {
        switch notificationAuthorization {
        case .authorized, .provisional, .ephemeral:
            return I18n.t("general.notification_status_authorized")
        case .denied:
            return I18n.t("general.notification_status_denied")
        default:
            return I18n.t("general.notification_status_not_determined")
        }
    }

    private func refreshNotificationPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationAuthorization = settings.authorizationStatus
        }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            notificationAuthorization = await center.notificationSettings().authorizationStatus
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
