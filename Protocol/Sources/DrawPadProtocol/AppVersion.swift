//
//  AppVersion.swift
//  DrawPadProtocol
//
//  The running app's marketing version, read the same way on both the
//  iPad app and the Mac receiver so version-compatibility messaging (see
//  Codec.swift's `incompatibleVersion` error) can name an actual version
//  number rather than just the internal protocol version.
//

import Foundation

public enum AppVersion {
    /// `CFBundleShortVersionString` (`MARKETING_VERSION` in the Xcode
    /// project) of whichever app this code is running inside.
    public static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
