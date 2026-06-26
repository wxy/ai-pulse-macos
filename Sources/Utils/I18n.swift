import Foundation

enum I18n {
    static let zh: [String: String] = [
        "menu.loading": "加载中…",
        "menu.no_usage": "本周无 AI 使用记录",
        "menu.unavailable": "统计不可用",
        "menu.by_model": "▸ 按模型",
        "menu.by_repo": "▸ 按仓库",
        "menu.preferences": "偏好设置…",
        "menu.quit": "退出",
        "menu.calls": "次调用",
        "menu.tokens": "tokens",
        "menu.lines": "行",
        "menu.per_line": "/行",
        "settings.title": "AI Pulse 偏好设置",
        "settings.general": "通用",
        "settings.coding_tools": "编程工具",
        "settings.repos": "仓库",
        "settings.subscriptions": "订阅",
        "settings.pricing": "定价",
        "settings.about": "关于",
        "settings.language": "语言",
        "settings.language_zh": "中文",
        "settings.language_en": "English",
        "general.title": "通用",
        "general.desc": "应用全局设置。",
        "general.language_label": "显示语言",
        "tools.title": "编程工具",
        "tools.desc": "自动检测的 AI 编程工具。",
        "tools.no_tools": "未检测到编程工具",
        "tools.sessions": "个会话",
        "tools.claude_code": "Claude Code",
        "repos.title": "Git 仓库",
        "repos.directories": "目录",
        "repos.repositories": "仓库",
        "repos.add": "添加目录",
        "repos.no_repos": "未发现仓库",
        "repos.select_dir": "选择一个目录",
        "repos.summary": "%d 个目录 · %d 个仓库",
        "repos.delete_title": "移除目录",
        "repos.delete_msg": "停止监控 '%@'？\n其仓库将不再被追踪。",
        "repos.cancel": "取消",
        "repos.remove": "移除",
        "subs.title": "订阅工具",
        "subs.desc": "月费工具。单行成本 = 月费 / 净提交行数。",
        "subs.add": "添加",
        "subs.choose": "选择预设…",
        "subs.delete_title": "移除订阅",
        "subs.delete_msg": "移除 '%@'？",
        "subs.per_month": "/月",
        "subs.empty": "未添加订阅。从上方选择一个预设。",
        "pricing.title": "模型定价",
        "pricing.desc": "每百万 token 价格 (USD)。",
        "pricing.model": "模型",
        "pricing.input": "输入",
        "pricing.output": "输出",
        "about.title": "AI Pulse",
        "about.version": "版本 M1 (0.1.0)",
        "about.desc": "知道你 AI 编程的真实成本。",
        "about.privacy": "所有数据仅存储在本机。",
    ]

    static let en: [String: String] = [
        "menu.loading": "Loading…",
        "menu.no_usage": "No AI usage this week",
        "menu.unavailable": "Stats unavailable",
        "menu.by_model": "▸ By Model",
        "menu.by_repo": "▸ By Repo",
        "menu.preferences": "Preferences…",
        "menu.quit": "Quit",
        "menu.calls": "calls",
        "menu.tokens": "tokens",
        "menu.lines": "lines",
        "menu.per_line": "/line",
        "settings.title": "AI Pulse Preferences",
        "settings.general": "General",
        "settings.coding_tools": "Coding Tools",
        "settings.repos": "Repos",
        "settings.subscriptions": "Subscriptions",
        "settings.pricing": "Pricing",
        "settings.about": "About",
        "settings.language": "Language",
        "settings.language_zh": "中文",
        "settings.language_en": "English",
        "general.title": "General",
        "general.desc": "Global application settings.",
        "general.language_label": "Display Language",
        "tools.title": "Coding Tools",
        "tools.desc": "AI coding tools auto-detected on your machine.",
        "tools.no_tools": "No coding tools detected.",
        "tools.sessions": "sessions",
        "tools.claude_code": "Claude Code",
        "repos.title": "Git Repositories",
        "repos.directories": "Directories",
        "repos.repositories": "Repositories",
        "repos.add": "Add Directory",
        "repos.no_repos": "No repos found.",
        "repos.select_dir": "Select a directory.",
        "repos.summary": "%d dirs · %d repos",
        "repos.delete_title": "Remove Directory",
        "repos.delete_msg": "Stop monitoring '%@'?\nIts repos will no longer be tracked.",
        "repos.cancel": "Cancel",
        "repos.remove": "Remove",
        "subs.title": "Subscription Tools",
        "subs.desc": "Monthly fee tools. Cost per line = fee / net committed lines.",
        "subs.add": "Add",
        "subs.choose": "Choose preset…",
        "subs.delete_title": "Remove Subscription",
        "subs.delete_msg": "Remove '%@'?",
        "subs.per_month": "/mo",
        "subs.empty": "No subscriptions added. Choose a preset above.",
        "pricing.title": "Model Pricing",
        "pricing.desc": "Price per million tokens (USD).",
        "pricing.model": "Model",
        "pricing.input": "Input",
        "pricing.output": "Output",
        "about.title": "AI Pulse",
        "about.version": "Version M1 (0.1.0)",
        "about.desc": "Know what AI coding really costs you.",
        "about.privacy": "All data stays on your machine.",
    ]

    static let didChangeLanguage = Notification.Name("I18nDidChangeLanguage")

    private static let langKey = "app_language"
    private static var currentLang: String?

    static func setLang(_ lang: String) {
        currentLang = lang
        UserDefaults.standard.set(lang, forKey: langKey)
        NotificationCenter.default.post(name: didChangeLanguage, object: nil)
    }

    static func getLang() -> String {
        if let l = currentLang { return l }
        let saved = UserDefaults.standard.string(forKey: langKey)
        let lang = saved ?? (Locale.current.language.languageCode?.identifier == "zh" ? "zh" : "en")
        currentLang = lang
        return lang
    }

    static func t(_ key: String) -> String {
        let dict = getLang() == "zh" ? zh : en
        return dict[key] ?? en[key] ?? key
    }
}
