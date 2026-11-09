import Foundation

/// Where the running Euclid.app lives. Opened straight from the disk image (or from Downloads, which
/// macOS runs from a random read-only copy, "App Translocation"), it vanishes when the image is
/// ejected or the Mac restarts: the login item points nowhere and updates can't replace it.
public enum InstallLocation {
    /// True for a bundle on a mounted volume or in a translocated copy.
    public static func isTemporary(bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }
}
