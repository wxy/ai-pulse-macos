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

private struct RobotWave: Shape {
    var amplitude: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0...100 {
            let x = CGFloat(i) / 100
            let wave = sin(x * .pi * 7) * (0.45 + 0.3 * sin(x * .pi * 3)) + 0.2 * sin(x * .pi * 17)
            let p = CGPoint(x: x * rect.width, y: rect.midY + wave * amplitude * rect.height * 0.42)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
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
    private var plate: Color { Color(light: Color(red: 0.90, green: 0.91, blue: 0.89), dark: Color(red: 0.17, green: 0.19, blue: 0.18)) }
    private let greens: [Color] = [.marsGreenBar, Color(red: 0.37, green: 0.53, blue: 0.40), Color(red: 0.53, green: 0.64, blue: 0.49), Color(red: 0.69, green: 0.73, blue: 0.61)]
    private let reds: [Color] = [.deepRed, Color(red: 0.68, green: 0.38, blue: 0.32), Color(red: 0.76, green: 0.53, blue: 0.44), Color(red: 0.81, green: 0.68, blue: 0.57)]
    private func t(_ zh: String, _ en: String) -> String { PhoneText.t(zh, en) }
    private func count(_ value: Int64) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if cloud.isPreview { Text(t("预览数据 · 不连接 iCloud", "Preview · iCloud disconnected")).font(.caption).foregroundStyle(.secondary).padding(.bottom, 12) }
                Capsule().fill(plate).frame(width: 4, height: 15)
                    .overlay(alignment: .top) { Circle().fill(Color.marsGreen).frame(width: 9, height: 9).offset(y: -5) }
                head
                    .aspectRatio(1, contentMode: .fit)
                    .background(plate, in: RoundedRectangle(cornerRadius: 32))
                    .overlay(RoundedRectangle(cornerRadius: 32).stroke(.primary.opacity(0.08)))
                    .overlay(alignment: .leading) { ear(left: true).offset(x: -19) }
                    .overlay(alignment: .trailing) { ear(left: false).offset(x: 19) }
                RoundedRectangle(cornerRadius: 4).fill(plate).frame(width: 100, height: 14)
                expenses
                    .background(plate, in: RoundedRectangle(cornerRadius: 24))
            }
            .compositingGroup()
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.18), radius: 15, y: 8)
            .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 30)
        }
        .background(Color(.systemBackground))
        .navigationTitle(t("仪表盘", "Dashboard"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { PhoneSettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel(t("设置", "Settings")) } }
        .task(id: range) { try? await cloud.fetchSnapshot(for: range) }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await cloud.fetchCurrentPulse()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .refreshable { await cloud.fetchAndStore(range: range); cloud.loadSnapshot(for: range); await cloud.fetchCurrentPulse() }
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
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let pulse = cloud.pulseEnvelope?.currentPulse(asOf: context.date)
                    let resting = pulse?.tier == .resting
                    let active = pulse?.tier == .active
                    let color: Color = pulse == nil || resting ? .secondary : active ? .marsGreenBar : Color(red: 0.72, green: 0.58, blue: 0.22)
                    Button { detail = t("当前活动强度", "Current activity") } label: {
                        HStack(spacing: 10) {
                            RobotWave(amplitude: pulse == nil || resting ? 0.07 : active ? 0.55 : 1).stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)).frame(maxWidth: .infinity).frame(height: 35)
                            Text(pulse == nil ? (cloud.pulseEnvelope?.pulse == nil ? t("暂无当前观测", "No current signal") : t("观测已过期", "Signal expired")) : resting ? t("平静", "Resting") : active ? t("活跃", "Active") : t("高强度", "Intense")).font(.caption.weight(.medium)).foregroundStyle(color)
                        }.padding(.horizontal, 12).padding(.vertical, 5).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain).accessibilityLabel(t("查看当前活动强度依据", "Current activity details"))
                }
                HStack(spacing: 3) {
                    ForEach(["today", "week", "30d"], id: \.self) { key in
                        Button { range = key } label: {
                            Text(key == "today" ? t("今日", "Today") : key == "week" ? t("本周", "Week") : t("30 天", "30 days"))
                                .font(.caption.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(range == key ? Color.marsGreen.opacity(scheme == .dark ? 0.22 : 0.13) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(.primary.opacity(0.035), in: Capsule()).padding(.horizontal, 26)
                HStack(alignment: .top, spacing: 8) {
                    eye(tokens: true)
                    nose.frame(width: 31).padding(.top, 25)
                    eye(tokens: false)
                }
                Button { detail = t("活动节奏", "Activity rhythm") } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 3) { Text(t("活动节奏（词元｜行数）", "Activity rhythm (tokens | lines)")); Image(systemName: "chevron.right").font(.system(size: 8)) }.font(.system(size: 10)).foregroundStyle(.secondary)
                        rhythm(tokens: true).frame(height: 16)
                        rhythm(tokens: false).frame(height: 16)
                    }.padding(9).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).padding(.horizontal, 20)
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ear(left: Bool) -> some View {
        Button { muted.toggle() } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11)).scaleEffect(x: left ? -1 : 1, y: 1)
                .frame(width: 23, height: 59).background(plate, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(muted ? t("开启 iPhone 声音", "Unmute iPhone") : t("静音 iPhone", "Mute iPhone"))
    }

    private func parts(tokens: Bool) -> [(String, Double)] {
        if tokens { return (snap?.toolBreakdown ?? []).map { ($0.name, Double($0.tokens ?? 0)) }.sorted { $0.1 > $1.1 } }
        return (snap?.topRepos ?? []).map { ($0.name, Double($0.totalChanges)) }.sorted { $0.1 > $1.1 }
    }
    private func eye(tokens: Bool) -> some View {
        let values = parts(tokens: tokens)
        let palette = tokens ? greens : reds
        let total = values.reduce(0) { $0 + $1.1 }
        let value = tokens ? snap.map { $0.todayTokens == 0 && !$0.readFailures.isEmpty ? "—" : count($0.todayTokens) } : values.isEmpty ? nil : count(Int64(total))
        return VStack(spacing: 6) {
            Button { detail = tokens ? t("工具与模型", "Tools & models") : t("仓库变化", "Repository changes") } label: {
                ZStack {
                    Circle().stroke(.primary.opacity(0.13), lineWidth: 0.6).padding(1)
                    Circle().stroke(.primary.opacity(0.07), lineWidth: 10).padding(7)
                    ForEach(Array(values.enumerated()), id: \.offset) { index, item in
                        let start = total > 0 ? values.prefix(index).reduce(0) { $0 + $1.1 } / total : 0
                        Circle().trim(from: start, to: total > 0 ? start + item.1 / total : 0).stroke(palette[index % 4], style: StrokeStyle(lineWidth: 10, lineCap: .butt)).rotationEffect(.degrees(-90)).padding(7)
                    }
                    VStack(spacing: 2) { Text(value ?? "—").font(.system(size: 21, weight: .semibold, design: .rounded)).minimumScaleFactor(0.65); Text(tokens ? "TOKENS" : "LINES").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary) }.padding(15)
                }.aspectRatio(1, contentMode: .fit)
            }.buttonStyle(.plain)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], alignment: .leading, spacing: 3) {
                ForEach(Array(values.prefix(4).enumerated()), id: \.offset) { i, item in HStack(spacing: 3) { Circle().fill(palette[i]).frame(width: 4, height: 4); Text(item.0).font(.system(size: 10)).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading) }
            }.frame(height: 27, alignment: .top)
            Button { detail = tokens ? t("工具与模型", "Tools & models") : t("仓库变化", "Repository changes") } label: { HStack(spacing: 2) { Text(tokens ? t("工具与模型", "Tools & models") : t("全部仓库", "All repositories")); Image(systemName: "chevron.right") }.font(.system(size: 9)) }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity)
    }

    private var nose: some View {
        let c = snap?.tokenComposition
        let values = [c?.nonCachedInput ?? 0, c?.cachedInput ?? 0, c?.output ?? 0]
        let widths = PhoneDashboardData.noseWidths(values)
        let totalInput = Double(values[0]) + Double(values[1])
        return Button { detail = t("词元构成", "Token composition") } label: {
            VStack(spacing: 4) {
                GeometryReader { geo in HStack(spacing: 0) { ForEach(0..<3) { i in Rectangle().fill(i == 0 ? Color.marsGreenBar : i == 1 ? Color(light: Color(red: 0.63, green: 0.67, blue: 0.58), dark: Color(red: 0.36, green: 0.41, blue: 0.33)) : Color.deepRed).frame(width: geo.size.width * widths[i]) } } }.frame(height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                Text(c == nil || totalInput == 0 ? "—" : "\(Int(Double(values[1]) / totalInput * 100))%")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain).accessibilityLabel(t("缓存率与词元构成", "Cache rate and token composition"))
    }

    private func rhythm(tokens: Bool) -> some View {
        let values = snap.map { PhoneDashboardData.rhythm(tokens ? $0.dailyStats : $0.codeChanges, period: $0.period, tokens: tokens) } ?? Array(repeating: -1, count: 24)
        let peak = max(1, values.max() ?? 1)
        return GeometryReader { geo in HStack(alignment: .bottom, spacing: 2) { ForEach(values.indices, id: \.self) { i in RoundedRectangle(cornerRadius: 1).fill(values[i] < 0 ? Color.secondary.opacity(0.15) : (tokens ? Color.marsGreenBar : Color.deepRed).opacity(values[i] == 0 ? 0.15 : 0.9)).frame(height: values[i] < 0 ? 3 : max(2, geo.size.height * values[i] / peak)).frame(maxWidth: .infinity) } }.frame(height: geo.size.height, alignment: .bottom) }
    }
    private var spendText: String {
        guard let items = snap?.observedSpend, !items.isEmpty else { return "—" }
        let sums = Dictionary(grouping: items, by: \.currency).map { currency, items in "\(currency) \(items.reduce(0) { $0 + $1.amount }.formatted(.number.precision(.fractionLength(2))))" }
        return sums.sorted().joined(separator: " · ")
    }
    private var expenses: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                expense(t("API 已观测支出", "Observed API spend"), value: spendText)
                Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 36)
                expense(t("固定月费", "Fixed monthly fees"), value: snap?.declaredMonthlyCostUSD.map { "USD \($0.formatted(.number.precision(.fractionLength(2))))" } ?? "—")
            }
            Divider()
            Button { detail = t("数据说明", "Data details") } label: {
                VStack(spacing: 4) {
                    Text(snap.map { t("Mac 上次数据更新 ", "Last Mac observation ") + $0.updatedAt.formatted(date: .abbreviated, time: .shortened) } ?? t("此范围尚无数据", "No snapshot for this range"))
                    if !(snap?.readFailures ?? []).isEmpty { Text(t("部分数据读取失败", "Some source reads failed")) }
                    Text(cloud.rangeErrors[range] == nil ? t("本地缓存 · 数据 v2", "Local cache · data v2") : t("同步未成功 · 显示已有缓存", "Sync failed · showing cached data"))
                }.font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.buttonStyle(.plain)
        }.padding(18)
    }
    private func expense(_ title: String, value: String) -> some View {
        Button { detail = title } label: { VStack(alignment: .leading, spacing: 7) { HStack(spacing: 3) { Text(title); Image(systemName: "chevron.right") }.font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(2).minimumScaleFactor(0.7) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
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
