import Testing
@testable import EuclidCore

struct InstallLocationTests {
    @Test(arguments: [
        "/Volumes/Euclid/Euclid.app",
        "/private/var/folders/x1/abc/T/AppTranslocation/6B2F1C3E-1111-2222-3333-444455556666/d/Euclid.app",
    ])
    func openedFromTheDownloadIsTemporary(path: String) {
        #expect(InstallLocation.isTemporary(bundlePath: path))
    }

    @Test(arguments: ["/Applications/Euclid.app", "/Users/me/Applications/Euclid.app", "/opt/homebrew/Caskroom/euclid/Euclid.app"])
    func installedCopiesAreNot(path: String) {
        #expect(!InstallLocation.isTemporary(bundlePath: path))
    }
}
