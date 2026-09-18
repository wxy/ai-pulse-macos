import SwiftUI
import AIPulseShared

/// Presentation arithmetic only: equal weight for additions and deletions.
/// Saturation prevents corrupt/extreme snapshots overflowing integer labels.
struct CodeChangeComposition: Equatable {
    let added: Int64
    let deleted: Int64

    init(added: Int64, deleted: Int64) {
        self.added = max(0, added)
        self.deleted = max(0, deleted)
    }

    static func sum(_ values: [Self]) -> Self {
        func add(_ a: Int64, _ b: Int64) -> Int64 {
            let result = a.addingReportingOverflow(b)
            return result.overflow ? Int64.max : result.partialValue
        }
        return values.reduce(Self(added: 0, deleted: 0)) {
            Self(added: add($0.added, $1.added), deleted: add($0.deleted, $1.deleted))
        }
    }

    var total: Double { Double(added) + Double(deleted) }
    var deletedFraction: Double? { total > 0 ? Double(deleted) / total : nil }
    var addedFraction: Double? { total > 0 ? Double(added) / total : nil }

    static func period(in snapshot: DashboardSnapshot?) -> Self? {
        guard let snapshot, !snapshot.readFailures.contains("dashboardCodeChanges") else { return nil }
        return sum(snapshot.codeChanges.map { Self(added: Int64($0.added), deleted: Int64($0.deleted)) })
    }

    static func repositoryTotals(in snapshot: DashboardSnapshot?) -> [String: Self]? {
        guard let snapshot, !snapshot.readFailures.contains("repositoryCode") else { return nil }
        return repositories(snapshot.topRepos)
    }

    static func repositories(_ repos: [RepoItem]) -> [String: Self] {
        Dictionary(grouping: repos, by: \.repoPath).mapValues {
            sum($0.map { Self(added: Int64($0.added), deleted: Int64($0.deleted)) })
        }
    }
}

/// Only vertical height encodes the ratio; area does not encode magnitude.
struct CodeChangeTrapezoid: Shape {
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
