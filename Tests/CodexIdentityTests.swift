import XCTest
@testable import AIPulse

final class CodexIdentityTests: XCTestCase {
    func testActivityLabelMatchesStableLogSourceWithoutRenamingAccountContext() {
        let integration = CodexIntegration()
        XCTAssertEqual(integration.id, "codex")
        XCTAssertEqual(integration.displayName, "Codex")
        XCTAssertEqual(IntegrationRegistry.toolDisplayName(for: integration.id), integration.displayName)
        XCTAssertNotNil(SubscriptionRegistry.tool(forName: "ChatGPT"))
    }
}
