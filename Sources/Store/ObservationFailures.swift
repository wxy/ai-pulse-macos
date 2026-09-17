/// Per-build query failures; never shared between period builds.
actor ObservationFailures {
    private var labels: Set<String> = []
    func record(_ label: String) { labels.insert(label) }
    func snapshot() -> [String] { labels.sorted() }
}
