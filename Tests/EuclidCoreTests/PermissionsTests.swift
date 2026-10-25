import Foundation
import Testing
@testable import EuclidCore

@Suite struct PermissionsTests {
    func state(ax: Bool = true, expansion: Bool = false, safari: Bool = false, asked: Bool = false) -> Permissions.State {
        .init(accessibility: ax, expansionEnabled: expansion, safariBlocked: safari, safariRequested: asked)
    }

    @Test func nothingMissingSaysSo() {
        let needs = Permissions.missing(state())
        #expect(needs.isEmpty)
        #expect(Permissions.footer(needs) == nil)
        #expect(Permissions.summary(needs) == "Everything Euclid uses is allowed")
    }

    @Test func accessibilityIsOnlyRequiredOnceExpansionIsOn() {
        let off = Permissions.missing(state(ax: false))
        #expect(off.map(\.required) == [false])
        #expect(Permissions.footer(off) == nil)
        let on = Permissions.missing(state(ax: false, expansion: true))
        #expect(Permissions.footer(on) == "⚠︎ Euclid needs Accessibility access: type “permissions”")
        #expect(on[0].pane.absoluteString.hasSuffix("Privacy_Accessibility"))
    }

    @Test func safariNeedsFullDiskAccessOnlyWhenAskedFor() {
        let found = Permissions.missing(state(safari: true))
        #expect(Permissions.footer(found) == nil)
        #expect(Permissions.summary(found) == "Full Disk Access: Safari history in search (optional)")
        let asked = Permissions.missing(state(ax: false, expansion: true, safari: true, asked: true))
        #expect(Permissions.footer(asked) == "⚠︎ Euclid needs Accessibility and Full Disk Access access: type “permissions”")
    }

    @Test func requiredComeFirst() {
        let needs = Permissions.missing(state(ax: false, safari: true, asked: true))
        #expect(needs.map(\.kind) == [.fullDiskAccess, .accessibility])
    }
}
