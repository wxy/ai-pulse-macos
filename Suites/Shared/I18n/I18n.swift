import Foundation

/// Lightweight i18n for iOS/watchOS — mirrors macOS I18n pattern.
enum I18n {
    static let zh: [String: String] = [
        "dashboard.today": "今日",
        "dashboard.week": "本周",
        "dashboard.30d": "30 天",
        "dashboard.total": "合计",
        "dashboard.net_lines": "净增行",
        "dashboard.added": "新增行",
        "dashboard.deleted": "删除行",
        "dashboard.calls": "请求次数",
        "dashboard.tokens": "Token",
        "dashboard.sub_vs_api": "订阅 / API",
        "dashboard.by_tool": "按开发工具",
        "dashboard.by_repo": "按仓库",
        "dashboard.by_provider": "按供应商",
        "dashboard.daily_trend": "每日趋势",
        "dashboard.no_data": "暂无数据",
        "dashboard.updated_ago": "%@ 前更新",
        "dashboard.spent_month": "本月已花 $%.2f · 预计 $%.2f · 剩余 %d 天",
        "welcome.title": "AI Pulse",
        "welcome.subtitle": "AI 花费追踪仪表盘",
        "welcome.body": "数据由 macOS 版 AI Pulse 采集并同步到你的 iCloud。请先在 Mac 上安装 AI Pulse 以开始追踪。",
        "welcome.appstore": "在 App Store 获取 macOS 版",
        "time.today": "今日",
        "time.week": "本周",
        "time.30d": "30 天",
        "stat.api": "API",
        "stat.sub": "订阅",
        "chart.added": "新增",
        "chart.deleted": "删除",
        "loading": "检查 iCloud…",
        "updated": "更新于: ",
    ]
    static let en: [String: String] = [
        "dashboard.today": "Today",
        "dashboard.week": "Week",
        "dashboard.30d": "30 Days",
        "dashboard.total": "Total",
        "dashboard.net_lines": "Net Lines",
        "dashboard.added": "Added",
        "dashboard.deleted": "Deleted",
        "dashboard.calls": "Calls",
        "dashboard.tokens": "Tokens",
        "dashboard.sub_vs_api": "Sub vs API",
        "dashboard.by_tool": "By Tool",
        "dashboard.by_repo": "By Repo",
        "dashboard.by_provider": "By Provider",
        "dashboard.daily_trend": "Daily Trend",
        "dashboard.no_data": "No data",
        "dashboard.updated_ago": "Updated %@ ago",
        "dashboard.spent_month": "Spent $%.2f this month · $%.2f projected · %d days left",
        "welcome.title": "AI Pulse",
        "welcome.subtitle": "AI Spending Dashboard",
        "welcome.body": "Data is collected and synced to your iCloud by AI Pulse for macOS. Please install AI Pulse on your Mac to start tracking.",
        "welcome.appstore": "Get macOS version on the App Store",
        "time.today": "Today",
        "time.week": "This Week",
        "time.30d": "30 Days",
        "stat.api": "API",
        "stat.sub": "Sub",
        "chart.added": "Added",
        "chart.deleted": "Deleted",
        "loading": "Checking iCloud…",
        "updated": "Updated: ",
    ]

    /// Auto-follows system language. iOS has no app-internal language picker.
    static var lang: String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
    }

    static func t(_ key: String) -> String {
        let dict = lang == "zh" ? zh : en
        return dict[key] ?? en[key] ?? key
    }
}
