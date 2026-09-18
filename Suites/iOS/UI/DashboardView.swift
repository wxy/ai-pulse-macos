import SwiftUI
import AIPulseShared

extension Color {
    static let marsGreenBar = Color(light: .marsGreen, dark: Color(red: 0.49, green: 0.66, blue: 0.53))
    static let deepRedBar = Color.deepRed
    init(light: Color, dark: Color) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}
struct FrostedCard: ViewModifier {
    func body(content: Content) -> some View { content.padding(12).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14)) }
}

private struct RobotSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 0, y: 23, width: 440, height: 440), cornerSize: CGSize(width: 29, height: 29))
        path.addRect(CGRect(x: 182, y: 462, width: 76, height: 10))
        path.addRoundedRect(in: CGRect(x: 0, y: 471, width: 440, height: 128), cornerSize: CGSize(width: 16, height: 16))
        path.addRoundedRect(in: CGRect(x: -9, y: 223.5, width: 10, height: 39), cornerSize: CGSize(width: 4, height: 4))
        path.addRoundedRect(in: CGRect(x: 439, y: 223.5, width: 10, height: 39), cornerSize: CGSize(width: 4, height: 4))
        path.addEllipse(in: CGRect(x: 213.5, y: 0, width: 13, height: 13))
        path.addRect(CGRect(x: 219, y: 12, width: 2, height: 12))
        return path
    }
}

private struct RobotPulseCurve: Shape {
    var tier: PulseTier?
    func path(in rect: CGRect) -> Path {
        let strength: CGFloat = tier == nil || tier == .resting ? 0.15 : tier == .intense ? 1 : tier == .elevated ? 0.88 : 0.72
        // Unequal peaks and troughs follow the approved symbol; not a fabricated time series.
        let points: [(CGFloat, CGFloat)] = [(0,0),(0.18,0),(0.28,-0.28),(0.37,0.22),(0.46,-0.46),(0.57,0.42),(0.67,-0.18),(0.77,0.08),(0.87,0),(1,0)]
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        for index in 1..<points.count {
            let a = points[index-1], b = points[index]
            let x1 = rect.minX + rect.width * a.0, x2 = rect.minX + rect.width * b.0
            let y1 = rect.midY + rect.height * a.1 * strength, y2 = rect.midY + rect.height * b.1 * strength
            path.addCurve(to: CGPoint(x: x2, y: y2), control1: CGPoint(x: (x1+x2)/2, y: y1), control2: CGPoint(x: (x1+x2)/2, y: y2))
        }
        return path
    }
}

private struct CodeChangeTrapezoid: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.25
        let radius = min(6, min(rect.width, rect.height) * 0.12)
        // Round only the external contour. The two fills remain one contiguous
        // stack, so their internal ratio boundary is still a straight line.
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + inset + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - inset - radius, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - inset + radius * inset / max(rect.height, 1), y: rect.minY + radius), control: CGPoint(x: rect.maxX - inset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius * inset / max(rect.height, 1), y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius * inset / max(rect.height, 1), y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + inset - radius * inset / max(rect.height, 1), y: rect.minY + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + inset + radius, y: rect.minY), control: CGPoint(x: rect.minX + inset, y: rect.minY))
            path.closeSubpath()
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var cloud: CloudDataService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @AppStorage("phone_sound_muted") private var muted = false
    @State private var range = "today"
    @State private var detail: String?
    private var snap: DashboardSnapshot? { cloud.cachedSnapshot(for: range) }
    private var plate: Color { Color(light: Color(red: 233/255, green: 236/255, blue: 229/255), dark: Color(red: 0.14, green: 0.17, blue: 0.15)) }
    private var inset: Color { Color(light: Color(red: 248/255, green: 249/255, blue: 245/255), dark: Color(red: 0.19, green: 0.22, blue: 0.20)) }
    private var line: Color { Color(light: Color(red: 212/255, green: 218/255, blue: 209/255), dark: Color(red: 61/255, green: 73/255, blue: 63/255)) }
    private var earColor: Color { Color(light: Color(red: 218/255, green: 229/255, blue: 218/255), dark: Color(red: 0.32, green: 0.40, blue: 0.34)) }
    private var cacheColor: Color { scheme == .dark ? Color(red: 0.30, green: 0.43, blue: 0.36) : .marsGreenLight }
    private let palette: [Color] = [.deepRed, .marsGreen, .deepRed2, .marsGreen2]
    private func t(_ zh: String, _ en: String) -> String { PhoneText.t(zh, en) }
    private func count(_ value: Int64) -> String { ChartMath.compactCount(value) }

    var body: some View {
        GeometryReader { geometry in
            let width = min(440.0, geometry.size.width - 56)
            let scale = width / 440
            ScrollView {
                VStack(spacing: 12) {
                    if cloud.isPreview { Text(t("预览数据 · 不连接 iCloud", "Preview · iCloud disconnected")).font(.caption).foregroundStyle(.secondary) }
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Circle().fill(earColor).frame(width: 13, height: 13).overlay(Circle().stroke(line, lineWidth: 1))
                            Rectangle().fill(Color.marsGreenLight).frame(width: 2, height: 10)
                        }.frame(height: 23)
                        head.frame(width: 440, height: 440)
                            .background(plate, in: RoundedRectangle(cornerRadius: 29))
                            .overlay(RoundedRectangle(cornerRadius: 29).stroke(.primary.opacity(0.14)))
                            .overlay(alignment: .leading) { ear(left: true).offset(x: -20) }
                            .overlay(alignment: .trailing) { ear(left: false).offset(x: 20) }
                        Rectangle().fill(plate).frame(width: 76, height: 8)
                            .overlay(HStack { Rectangle().fill(.primary.opacity(0.14)).frame(width: 1); Spacer(); Rectangle().fill(.primary.opacity(0.14)).frame(width: 1) })
                        expenses.frame(width: 440, height: 128)
                    }
                    .background(RobotSilhouette().fill(plate).shadow(color: .black.opacity(0.27), radius: 14, y: 5))
                    .frame(width: 440, height: 599)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: width, height: 599 * scale, alignment: .topLeading)
                }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 30)
            }
            .refreshable { await cloud.fetchAndStore(range: range); cloud.loadSnapshot(for: range); await cloud.fetchCurrentPulse() }
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .task(id: range) { try? await cloud.fetchSnapshot(for: range) }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await cloud.fetchCurrentPulse()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    @ViewBuilder private var head: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 12) {
                Button { self.detail = nil } label: { Label(t("返回", "Back"), systemImage: "chevron.left") }.font(.subheadline.weight(.medium))
                Text(detail).font(.headline)
                ScrollView { detailContent(detail).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 9) {
                HStack(alignment: .top) {
                    Color.clear.frame(width: 16, height: 24)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        let pulse = cloud.pulseEnvelope?.currentPulse(asOf: context.date)
                        Button { detail = t("当前活动强度", "Current activity") } label: {
                            Group {
                                if pulse == nil { Text(cloud.pulseEnvelope?.pulse == nil ? t("暂无当前观测", "No current signal") : t("观测已过期", "Signal expired")).font(.system(size: 11)) }
                                else { RobotPulseCurve(tier: pulse?.tier).stroke(pulse?.tier == .active ? Color.marsGreen : pulse?.tier == .resting ? .secondary : .deepRed, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)).frame(width: 125, height: 38) }
                            }.frame(width: 270, height: 57).background(inset, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(line))
                        }.buttonStyle(.plain).accessibilityLabel(t("查看当前活动强度依据", "Current activity details"))
                    }
                    Spacer()
                    NavigationLink { PhoneSettingsView() } label: { Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(.secondary) }.accessibilityLabel(t("设置", "Settings"))
                }
                HStack(spacing: 0) {
                    ForEach(["today", "week", "30d"], id: \.self) { key in
                        Button { range = key } label: {
                            Text(key == "today" ? t("今日", "Today") : key == "week" ? t("本周", "Week") : t("30 天", "30 days"))
                                .font(.system(size: 11)).foregroundStyle(range == key ? (scheme == .dark ? Color(red: 0.76, green: 0.83, blue: 0.78) : .primary) : .secondary)
                                .frame(maxWidth: .infinity).frame(height: 24)
                                .background(range == key ? (scheme == .dark ? Color(red: 0.19, green: 0.30, blue: 0.24) : Color.white.opacity(0.8)) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).accessibilityAddTraits(range == key ? .isSelected : [])
                    }
                }.padding(2).frame(width: 240).background(inset, in: RoundedRectangle(cornerRadius: 8))
                HStack(alignment: .center, spacing: 16) {
                    eye(tokens: true)
                    nose
                    eye(tokens: false)
                }.frame(height: 200, alignment: .top)
                VStack(spacing: 5) {
                    HStack { Text(t("活动节奏（词元｜行数）", "Activity rhythm (Tokens | Lines)")); Spacer(); Text(range == "today" ? t("按小时", "Hourly") : t("按天", "Daily")) }.font(.system(size: 9)).foregroundStyle(.secondary)
                    rhythm(tokens: true).frame(height: 23)
                    rhythm(tokens: false).frame(height: 23)
                }.frame(width: 350, height: 70).padding(10)
                    .background(inset, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(line))
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ear(left: Bool) -> some View {
        Button { muted.toggle() } label: {
            RoundedRectangle(cornerRadius: 4).fill(earColor)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(line))
                .overlay { Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 10, weight: .medium)).scaleEffect(x: left ? -1 : 1, y: 1).foregroundStyle(muted ? Color.secondary : .primary.opacity(0.7)) }
                .frame(width: 16, height: 39).frame(width: 24, height: 47).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(muted ? t("开启 iPhone 声音", "Unmute iPhone") : t("静音 iPhone", "Mute iPhone"))
    }
    private func parts(tokens: Bool) -> [(String, Double)] {
        let values = tokens ? (snap?.toolBreakdown ?? []).map { ($0.name, Double($0.tokens ?? 0)) }
            : (snap?.topRepos ?? []).map { ($0.name, Double($0.totalChanges)) }
        let sorted = values.filter { $0.1 > 0 }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return sorted.count > 3 ? Array(sorted.prefix(3)) + [(t("其他", "Other"), sorted.dropFirst(3).reduce(0) { $0 + $1.1 })] : sorted
    }
    private func eye(tokens: Bool) -> some View {
        let values = parts(tokens: tokens)
        let total = values.reduce(0) { $0 + $1.1 }
        let value = tokens ? snap.map { $0.readFailures.contains("toolUsage") ? "—" : count(Int64(total)) } : values.isEmpty ? nil : count(Int64(total))
        return VStack(spacing: 6) {
            Text(tokens ? t("工具用量", "Tool usage") : t("仓库变化", "Repository changes")).font(.caption2).foregroundStyle(.secondary)
            Button { detail = tokens ? t("工具与模型", "Tools & models") : t("仓库变化", "Repository changes") } label: {
                ZStack {
                    Circle().fill(inset).frame(width: 120, height: 120)
                    Circle().stroke(line, lineWidth: 1).frame(width: 132, height: 132)
                    Circle().stroke(.primary.opacity(0.07), lineWidth: 10).frame(width: 110, height: 110)
                    ForEach(Array(values.enumerated()), id: \.offset) { index, item in
                        let start = total > 0 ? values.prefix(index).reduce(0) { $0 + $1.1 } / total : 0
                        Circle().trim(from: start, to: total > 0 ? start + item.1 / total : 0).stroke(palette[index % 4], style: StrokeStyle(lineWidth: 10, lineCap: .butt)).rotationEffect(.degrees(-90)).frame(width: 110, height: 110)
                    }
                    VStack(spacing: 2) { Text(value ?? "—").font(.system(size: 20, weight: .semibold, design: .rounded)).minimumScaleFactor(0.65); Text(tokens ? "TOKENS" : "LINES").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary) }.padding(15)
                }.frame(width: 132, height: 132)
            }.buttonStyle(.plain)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], alignment: .leading, spacing: 3) {
                ForEach(Array(values.prefix(4).enumerated()), id: \.offset) { i, item in HStack(spacing: 3) { Circle().fill(palette[i]).frame(width: 4, height: 4); Text(item.0).font(.system(size: 10)).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading) }
            }.frame(height: 27, alignment: .top)
            Button { detail = tokens ? t("工具与模型", "Tools & models") : t("仓库变化", "Repository changes") } label: { HStack(spacing: 2) { Text(tokens ? t("工具与模型", "Tools & models") : t("全部仓库", "All repositories")); Image(systemName: "arrow.up.right").font(.system(size: 8)) }.font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain)
        }.frame(width: 145)
    }

    private var nose: some View {
        let c = snap?.tokenComposition
        let values = [c?.nonCachedInput ?? 0, c?.cachedInput ?? 0, c?.output ?? 0]
        let widths = PhoneDashboardData.noseWidths(values)
        let totalInput = Double(values[0]) + Double(values[1])
        return Button { detail = t("词元构成", "Token composition") } label: {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(0..<3) { i in
                        Rectangle().fill(i == 0 ? Color.marsGreen : i == 1 ? cacheColor : .deepRed)
                            .opacity(values[i] > 0 ? 1 : 0.25).frame(width: geo.size.width * widths[i])
                            .overlay { if i == 1 { Text(c == nil || totalInput == 0 ? "—" : "\(Int(Double(values[1]) / totalInput * 100))%").font(.system(size: 8, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5) } }
                    }
                }.clipShape(CodeChangeTrapezoid())
            }.frame(width: 44, height: 55).opacity(c == nil ? 0.25 : 1)
        }.frame(width: 60).buttonStyle(.plain).accessibilityLabel(t("缓存率与词元构成", "Cache rate and token composition"))
    }

    private func rhythm(tokens: Bool) -> some View {
        let values = snap.map { PhoneDashboardData.rhythm(tokens ? $0.dailyStats : $0.codeChanges, period: $0.period, tokens: tokens) } ?? Array(repeating: -1, count: 24)
        let peak = max(1, values.max() ?? 1)
        return GeometryReader { geo in HStack(alignment: tokens ? .top : .bottom, spacing: 3) { ForEach(values.indices, id: \.self) { i in Capsule().fill(values[i] < 0 ? Color.secondary.opacity(0.15) : (tokens ? Color.marsGreen : Color.deepRed2).opacity(values[i] == 0 ? 0.15 : 0.9)).frame(height: values[i] < 0 ? 3 : max(3, geo.size.height * values[i] / peak)).frame(maxWidth: .infinity) } }.frame(height: geo.size.height, alignment: tokens ? .top : .bottom) }
    }
    private var spendText: String {
        guard let items = snap?.observedSpend, !items.isEmpty else { return "—" }
        let sums = Dictionary(grouping: items, by: \.currency).map { currency, items in "\(currency) \(items.reduce(0) { $0 + $1.amount }.formatted(.number.precision(.fractionLength(2))))" }
        return sums.sorted().joined(separator: " · ")
    }
    private var expenses: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                expense(t("账户观测", "Account observations"), value: spendText, link: t("账户观测明细", "Observation details"), detail: t("API 已观测支出", "Observed API spend"))
                Divider()
                expense(t("固定月费 · 声明值", "Fixed monthly fees · declared"), value: snap?.declaredMonthlyCostUSD.map { "USD \($0.formatted(.number.precision(.fractionLength(2))))" + t(" / 月", " / mo") } ?? "—", link: t("固定费用说明", "Fixed cost context"), detail: t("固定月费", "Fixed monthly fees"))
            }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            VStack(spacing: 5) {
                HStack {
                    Text(snap.map { t("Mac 上次更新 ", "Last Mac observation ") + $0.updatedAt.formatted(date: .omitted, time: .shortened) } ?? t("此范围尚无数据", "No snapshot for this range"))
                    Spacer()
                    Button { detail = t("数据说明", "Data details") } label: { Label(t("数据说明", "Data details"), systemImage: "arrow.up.right") }
                }
                HStack { Text("AI Pulse " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")); Spacer(); Text(t("数据版本 ", "Data format ") + (snap?.payloadVersion ?? "2.0.0")) }
            }.font(.system(size: 9)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10).background(.primary.opacity(0.035))
        }.background(inset, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.14))).buttonStyle(.plain)
    }
    private func expense(_ title: String, value: String, link: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            Button { self.detail = detail } label: { HStack(spacing: 4) { Text(link); Image(systemName: "arrow.up.right").font(.system(size: 8)) }.font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func detailContent(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if title == t("当前活动强度", "Current activity") {
                Text(t("这是 Mac 最近的活动观测，不随统计范围切换。过期观测不代表平静。", "Recent Mac activity, independent of the selected period. An expired observation does not mean resting."))
                if let pulse = cloud.pulseEnvelope?.currentPulse() { Text(I18n.pulseReason(pulse)); if let facts = pulse.activityFacts { row(t("最近词元", "Recent tokens"), count(facts.recentTokens)); row(t("观测窗口", "Observation window"), "\(facts.windowSeconds / 60) min") } }
                else { Text(t("尚无有效的当前强度，请确认 Mac 正在运行并同步。", "No valid current signal. Check that your Mac is running and syncing.")) }
            } else if title == t("词元构成", "Token composition") {
                if let c = snap?.tokenComposition { row(t("非缓存输入", "Uncached input"), count(c.nonCachedInput)); row(t("缓存输入", "Cached input"), count(c.cachedInput)); row(t("输出", "Output"), count(c.output)); Text(t("缓存属于输入。鼻梁采用非线性宽度，让较小部分也可见；数值按实际数据展示。", "Cache is a subset of input. Nonlinear widths keep small components visible; counts are actual observations.")) } else { Text(t("尚无词元构成数据", "No composition data")) }
            } else if title == t("工具与模型", "Tools & models") {
                ForEach(Array((snap?.toolBreakdown ?? []).enumerated()), id: \.offset) { _, item in row(item.name, item.tokens.map(count) ?? "—") }
                Divider()
                ForEach(Array((snap?.modelBreakdown ?? []).enumerated()), id: \.offset) { _, item in row(item.model, count(item.tokens)) }
                if (snap?.toolBreakdown ?? []).isEmpty { Text(t("尚无工具活动数据", "No tool activity data")) }
            } else if title == t("仓库变化", "Repository changes") {
                ForEach(snap?.topRepos ?? []) { repo in VStack(alignment: .leading, spacing: 4) { row(repo.name, "+\(repo.added) / −\(repo.deleted)"); Text(repo.repoPath).font(.caption).foregroundStyle(.secondary) } }
                if (snap?.topRepos ?? []).isEmpty { Text(t("未观测到仓库变化；可在 Mac 上配置开发目录。", "No repository changes observed. Configure development directories on your Mac.")) }
            } else if title == t("活动节奏", "Activity rhythm") {
                Text(t("按 Mac 时区统计。上行为词元，下行为新增与删除行数。灰色侧栏是相邻周占位，不代表已观测活动。", "Uses your Mac’s time zone. Tokens above, added and deleted lines below. Gray neighboring weeks are placeholders."))
                rhythm(tokens: true).frame(height: 50); rhythm(tokens: false).frame(height: 50)
                ForEach(Array((snap?.dailyStats ?? []).enumerated()), id: \.offset) { _, point in row(Date(timeIntervalSince1970: point.ts).formatted(date: .abbreviated, time: .shortened), count(point.tokens)) }
            } else if title == t("API 已观测支出", "Observed API spend") {
                Text(t("账户返回的已观测支出，保留原币种与观测区间，不等同于选定范围的全部消费。", "Account observations retain their currency and observation interval; they are not the entire spend for the selected period."))
                ForEach(Array((snap?.observedSpend ?? []).enumerated()), id: \.offset) { _, item in VStack(alignment: .leading, spacing: 4) { row(item.providerId, "\(item.currency) \(item.amount.formatted(.number.precision(.fractionLength(2))))"); Text(Date(timeIntervalSince1970: item.observedAt).formatted()).font(.caption).foregroundStyle(.secondary) } }
                ForEach(Array((snap?.remainingBalances ?? []).enumerated()), id: \.offset) { _, item in row(item.displayName, "\(item.currency) \(item.balance.formatted())") }
            } else if title == t("固定月费", "Fixed monthly fees") {
                Text(t("由 Mac 设置中的套餐与固定费用声明汇总，单位为 USD/月。它不表示已用额度，也不与 API 观测支出相加。请在 Mac 上修改。", "Declared plans and fixed fees from Mac settings, in USD/month. This is not consumed quota and is not added to API observations. Edit on your Mac."))
                row(t("月费", "Monthly fees"), snap?.declaredMonthlyCostUSD.map { "USD \($0.formatted())" } ?? "—")
            } else {
                Text(t("这里只显示 Mac 同步的摘要。词元、代码变化和账户费用各有独立的数据来源。缺失数据不代表零。", "Mac-synced summaries only. Tokens, code changes and account observations have independent sources. Missing data is not zero."))
                row(t("数据版本", "Data version"), snap?.payloadVersion ?? "—"); row(t("Mac 版本", "Mac version"), snap?.writerAppVersion ?? "—")
                if let snap { row(t("已观测事件", "Observed events"), snap.activityCoverage.observedEvents.map(count) ?? "—"); ForEach(snap.readFailures, id: \.self) { Text($0).foregroundStyle(.secondary) } }
            }
        }.font(.subheadline).textSelection(.enabled)
    }
    private func row(_ key: String, _ value: String) -> some View { HStack(alignment: .top) { Text(key); Spacer(minLength: 8); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) } }
}
