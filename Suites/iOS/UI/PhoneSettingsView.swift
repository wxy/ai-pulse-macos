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
    @AppStorage("phone_sound_muted") private var muted = false
    @State private var status = "—"
    @State private var permission = "—"
    private func t(_ zh: String, _ en: String) -> String { PhoneText.t(zh, en) }
    var body: some View {
        Form {
            Section("iCloud") {
                LabeledContent(t("连接状态", "Connection"), value: status)
                Text(t("iPhone 读取 Mac 2.0 的摘要。两端需要使用同一 Apple 账户，Mac 需开启 iCloud 同步。", "iPhone reads Mac 2.0 summaries. Use the same Apple account and enable iCloud sync on your Mac."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let date = cloud.lastUpdated { LabeledContent(t("Mac 数据更新", "Mac observation"), value: date.formatted(date: .abbreviated, time: .shortened)) }
                Button(t("重新同步", "Sync again")) { Task { await cloud.fetchAndStore(range: cloud.currentRange); cloud.loadSnapshot(for: cloud.currentRange); await cloud.fetchCurrentPulse(); await checkStatus() } }.disabled(cloud.isPreview)
            }
            Section(t("此 iPhone", "This iPhone")) {
                Toggle(t("静音", "Mute sounds"), isOn: $muted)
                LabeledContent(t("通知授权", "Notifications"), value: permission)
                Button(t("启用通知", "Enable notifications")) {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                        await NotificationService.shared.setup()
                        await checkStatus()
                    }
                }.disabled(cloud.isPreview)
                Button(t("打开系统设置", "Open system settings")) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                Text(t("这里的静音仅影响 iPhone，不修改 Mac。目录授权、套餐和 API Key 请在 Mac 上配置。", "Mute applies to this iPhone only. Configure directories, plans and API keys on your Mac.")).font(.footnote).foregroundStyle(.secondary)
            }
            Section(t("版本", "Version")) {
                LabeledContent(t("应用版本", "App version"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent(t("数据格式", "Data format"), value: CKSchema.payloadVersion)
            }
        }.navigationTitle(t("设置", "Settings"))
            .task { await checkStatus() }
    }
    private func checkStatus() async {
        if cloud.isPreview { status = t("预览模式", "Preview mode"); permission = "—"; return }
        guard CloudDataService.cloudAvailable else { status = t("模拟器未启用云端访问", "Cloud access unavailable in simulator"); permission = "—"; return }
        do {
            let result = try await CloudKitGate.shared.run("phoneAccountStatus") { try await CKContainer(identifier: "iCloud.com.wxy.aipulse").accountStatus() }
            status = result == .available ? t("已登录", "Signed in") : t("不可用，请检查系统设置", "Unavailable; check system settings")
        } catch { status = t("连接未成功", "Connection failed") }
        let result = await UNUserNotificationCenter.current().notificationSettings()
        permission = result.authorizationStatus == .authorized || result.authorizationStatus == .provisional ? t("已授权", "Allowed") : t("未授权", "Not allowed")
    }
}
