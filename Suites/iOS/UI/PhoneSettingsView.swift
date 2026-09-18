import SwiftUI
import CloudKit
import UserNotifications
import AIPulseShared

enum PhoneText {
    static func t(_ zh: String, _ en: String) -> String {
        if I18n.lang.hasPrefix("zh-Hant") { return zh.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? zh }
        return I18n.lang == "zh-Hans" ? zh : en
    }
}

struct PhoneSettingsView: View {
    @EnvironmentObject private var cloud: CloudDataService
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("phone_sound_muted") private var muted = false
    @State private var status = "—"
    @State private var notificationSettings: UNNotificationSettings?
    @State private var syncing = false
    @State private var syncMessage: String?
    @State private var syncFailed = false
    @State private var lastSync: Date?
    @State private var requestingNotifications = false
    @State private var notificationError: String?
    private func t(_ zh: String, _ en: String) -> String { PhoneText.t(zh, en) }

    private var notificationStatus: String {
        guard let settings = notificationSettings else { return t("检查中…", "Checking…") }
        switch settings.authorizationStatus {
        case .notDetermined: return t("尚未启用", "Not enabled yet")
        case .denied: return t("已关闭", "Disabled")
        case .authorized: return t("已启用", "Enabled")
        case .provisional: return t("已启用安静通知", "Quiet notifications enabled")
        case .ephemeral: return t("临时授权", "Temporarily allowed")
        @unknown default: return t("状态未知", "Unknown")
        }
    }

    var body: some View {
        Form {
            Section("iCloud") {
                LabeledContent(t("连接状态", "Connection"), value: status)
                Text(t("iPhone 从 iCloud 读取 Mac 上传的摘要。重新同步不会触发 Mac 上传，也不会扫描本地开发日志。", "iPhone reads summaries uploaded by your Mac. Sync again fetches iCloud data; it does not trigger a Mac upload or scan development logs."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let date = cloud.lastUpdated { LabeledContent(t("Mac 数据更新", "Mac observation"), value: date.formatted(date: .abbreviated, time: .shortened)) }
                Button { Task { await syncAgain() } } label: {
                    HStack {
                        Text(syncing ? t("正在同步…", "Syncing…") : t("重新同步", "Sync again"))
                        Spacer()
                        if syncing { ProgressView() }
                    }
                }.disabled(cloud.isPreview || !CloudDataService.cloudAvailable || syncing)
                if let syncMessage {
                    Label(syncMessage, systemImage: syncFailed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.footnote).foregroundStyle(syncFailed ? Color.orange : Color.secondary)
                        .accessibilityLabel(syncMessage)
                }
                if let lastSync { LabeledContent(t("本机最近同步成功", "Last successful fetch"), value: lastSync.formatted(date: .omitted, time: .standard)) }
            }
            Section(t("此 iPhone", "This iPhone")) {
                Toggle(t("静音", "Mute sounds"), isOn: $muted)
                Text(t("静音仅影响此 iPhone，不修改 Mac。目录授权、套餐和 API Key 请在 Mac 上配置。", "Mute applies to this iPhone only. Configure directories, plans and API keys on your Mac."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(t("通知状态", "Notification status"), value: notificationStatus)
                if let settings = notificationSettings,
                   settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                    LabeledContent(t("通知声音", "Notification sounds"), value: settings.soundSetting == .enabled ? t("已开启", "On") : t("已关闭", "Off"))
                }
                if notificationSettings?.authorizationStatus == .notDetermined {
                    Button { Task { await enableNotifications() } } label: {
                        HStack {
                            Text(requestingNotifications ? t("正在启用…", "Enabling…") : t("启用通知", "Enable notifications"))
                            Spacer()
                            if requestingNotifications { ProgressView() }
                        }
                    }.disabled(cloud.isPreview || requestingNotifications)
                }
                Button(notificationSettings?.authorizationStatus == .denied ? t("前往系统设置启用通知", "Enable notifications in Settings") : t("在系统设置中管理通知", "Manage notifications in Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.disabled(cloud.isPreview)
                if let notificationError { Text(notificationError).font(.footnote).foregroundStyle(.orange) }
            } header: {
                Text(t("通知", "Notifications"))
            } footer: {
                Text(t("通知用于接收支出提醒。系统设置会打开 AI Pulse 的设置页，可进入“通知”修改允许通知、提醒方式和声音。已拒绝授权后，需在系统设置中重新开启。", "Notifications deliver spending alerts. This opens AI Pulse’s system settings, where Notifications controls permission, alert styles and sounds. If permission was denied, enable it there."))
            }
            Section(t("版本", "Version")) {
                LabeledContent(t("应用版本", "App version"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent(t("数据格式", "Data format"), value: CKSchema.payloadVersion)
            }
        }.navigationTitle(t("设置", "Settings")).toolbar(.visible, for: .navigationBar)
            .task { await checkStatus() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await checkStatus() } }
            }
    }

    private func syncAgain() async {
        guard !syncing else { return }
        syncing = true
        syncMessage = nil
        defer { syncing = false }
        for range in ["today", "week", "30d"] { await cloud.fetchAndStore(range: range, force: true) }
        cloud.loadSnapshot(for: cloud.currentRange)
        await cloud.fetchCurrentPulse(force: true)
        let failedRanges = ["today", "week", "30d"].filter { cloud.rangeErrors[$0] != nil }
        syncFailed = !failedRanges.isEmpty || cloud.pulseError != nil
        if syncFailed {
            syncMessage = t("未能完整读取云端数据，已保留本地缓存。请检查网络与 Mac 同步状态后重试。", "Could not fetch all cloud data. Local cached data is preserved. Check your network and Mac sync status, then retry.")
        } else {
            lastSync = Date()
            syncMessage = t("已读取最新云端摘要与强度。没有新数据时，仪表盘数值保持不变。", "Fetched the latest cloud summaries and activity. Dashboard values stay the same when no new data is available.")
        }
    }

    private func enableNotifications() async {
        guard !requestingNotifications else { return }
        requestingNotifications = true
        notificationError = nil
        defer { requestingNotifications = false }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            // Show the OS decision immediately, before CloudKit subscription work.
            await refreshNotificationStatus()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
                await NotificationService.shared.setup()
            }
        } catch {
            notificationError = t("无法申请通知授权，请稍后重试或前往系统设置。", "Could not request notification permission. Retry later or open system settings.")
            await refreshNotificationStatus()
        }
    }

    private func refreshNotificationStatus() async {
        notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        await NotificationService.refreshSoundSetting()
    }

    private func checkStatus() async {
        await refreshNotificationStatus()
        if cloud.isPreview { status = t("预览模式", "Preview mode"); return }
        guard CloudDataService.cloudAvailable else { status = t("模拟器未启用云端访问", "Cloud access unavailable in simulator"); return }
        do {
            let result = try await CloudKitGate.shared.run("phoneAccountStatus") { try await CKContainer(identifier: "iCloud.com.wxy.aipulse").accountStatus() }
            switch result {
            case .available: status = t("已登录", "Signed in")
            case .noAccount: status = t("尚未登录 Apple 账户", "Not signed into an Apple account")
            case .restricted: status = t("iCloud 访问受限", "iCloud access restricted")
            case .couldNotDetermine, .temporarilyUnavailable: status = t("暂时无法检查账户", "Account status temporarily unavailable")
            @unknown default: status = t("不可用，请检查系统设置", "Unavailable; check system settings")
            }
        } catch { status = t("连接未成功", "Connection failed") }
    }
}
