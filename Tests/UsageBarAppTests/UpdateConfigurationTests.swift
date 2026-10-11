import Foundation
import XCTest
@testable import UsageBar

final class UpdateConfigurationTests: XCTestCase {
    private let fixtureID = "dev.hyjoong.usagebar.updatetest"
    private let productionID = "dev.hyjoong.usagebar"
    private var validInfo: [String: Any] {
        ["SUFeedURL": "https://updates.example.com/usagebar/appcast.xml",
         "SUPublicEDKey": Data(repeating: 0x11, count: 32).base64EncodedString()]
    }

    func testValidHTTPSFeedAndPublicKeyEnableProductionUpdates() {
        let configuration = UpdateConfiguration(info: validInfo, bundleIdentifier: productionID, isDemo: false)
        XCTAssertTrue(configuration.isReady)
        XCTAssertFalse(configuration.statusMessage.isEmpty)
    }

    func testMissingMalformedOrWrongLengthPublicKeyNeverEnablesUpdates() {
        for key in [nil, "", "   ", "not-base64!", Data(repeating: 1, count: 31).base64EncodedString(),
                    Data(repeating: 1, count: 33).base64EncodedString()] as [String?] {
            var info = validInfo
            info["SUPublicEDKey"] = key
            let configuration = UpdateConfiguration(info: info, bundleIdentifier: productionID, isDemo: false)
            XCTAssertFalse(configuration.isReady, "Unexpected key accepted: \(String(describing: key))")
            XCTAssertFalse(configuration.statusMessage.isEmpty)
        }
    }

    func testProductionRejectsInsecureRelativeCredentialedAndFragmentFeeds() {
        let feeds: [String?] = [nil, "", "  ", "/appcast.xml", "//updates.example.com/appcast.xml",
            "http://updates.example.com/appcast.xml", "http://127.0.0.1:8123/appcast.xml",
            "file:///private/tmp/appcast.xml", "https:///appcast.xml", "https://user@example.com/feed.xml",
            "https://user:password@example.com/feed.xml", "https://example.com/feed.xml#fragment",
            "https://example.com/feed.xml#", "https://example.com/white space.xml",
            "https://example.com/feed.xml\n"]
        for feed in feeds {
            var info = validInfo
            info["SUFeedURL"] = feed
            XCTAssertFalse(UpdateConfiguration(info: info, bundleIdentifier: productionID, isDemo: false).isReady,
                           "Unexpected feed accepted: \(String(describing: feed))")
        }
    }

    func testOrdinaryDemoCannotEnableUpdatesEvenWithValidProductionSettings() {
        for bundleID in [productionID, "dev.hyjoong.usagebar.preview", fixtureID] {
            for allowsLocalFixture in [false, true] {
                let configuration = UpdateConfiguration(info: validInfo, bundleIdentifier: bundleID,
                                                        isDemo: true, allowsLocalFixture: allowsLocalFixture)
                XCTAssertFalse(configuration.isReady, "A fixture ID alone must not bypass demo isolation")
            }
        }
    }

    func testLocalHTTPRequiresExactFixtureIdentityFlagAndExplicitOptIn() {
        var info = validInfo
        info["SUFeedURL"] = "http://127.0.0.1:8123/appcast.xml"
        info["UsageBarUpdateTestMode"] = true
        XCTAssertFalse(UpdateConfiguration(info: info, bundleIdentifier: fixtureID, isDemo: true).isReady)
        for bundleID in [nil, productionID, "dev.hyjoong.usagebar.preview", fixtureID + ".extra"] as [String?] {
            XCTAssertFalse(UpdateConfiguration(info: info, bundleIdentifier: bundleID, isDemo: true,
                                               allowsLocalFixture: true).isReady)
            XCTAssertFalse(UpdateConfiguration(info: info, bundleIdentifier: bundleID, isDemo: false,
                                               allowsLocalFixture: true).isReady)
        }
        for flag in [false, "true"] as [Any] {
            info["UsageBarUpdateTestMode"] = flag
            XCTAssertFalse(UpdateConfiguration(info: info, bundleIdentifier: fixtureID, isDemo: true,
                                               allowsLocalFixture: true).isReady)
        }
    }

    func testFixtureFeedsAllowOnlyLoopbackHosts() {
        var info = validInfo
        info["UsageBarUpdateTestMode"] = true
        for scheme in ["http", "https"] {
            for host in ["localhost", "127.0.0.1", "[::1]"] {
                info["SUFeedURL"] = "\(scheme)://\(host):8123/appcast.xml"
                let configuration = UpdateConfiguration(info: info, bundleIdentifier: fixtureID,
                                                        isDemo: true, allowsLocalFixture: true)
                #if DEBUG
                XCTAssertTrue(configuration.isReady, "Valid isolated loopback fixture was rejected: \(scheme)://\(host)")
                #else
                XCTAssertFalse(configuration.isReady)
                #endif
            }
        }
        for feed in ["http://localhost.example.com/feed.xml", "http://127.0.0.1.example.com/feed.xml",
                     "https://updates.example.com/feed.xml", "https://localhost.example.com/feed.xml",
                     "http://localhost@evil.example/feed.xml", "http://user:password@localhost/feed.xml",
                     "http://0.0.0.0:8123/feed.xml", "http://192.168.1.10:8123/feed.xml",
                     "http://127.0.0.1:8123/feed.xml#fragment"] {
            info["SUFeedURL"] = feed
            XCTAssertFalse(UpdateConfiguration(info: info, bundleIdentifier: fixtureID, isDemo: true,
                                               allowsLocalFixture: true).isReady, feed)
        }
    }

    func testFixtureDetectionSurvivesMissingArgumentsAndBrokenUpdateSettings() {
        // Demo isolation must be based on bundle metadata, even if the updater is misconfigured.
        let info: [String: Any] = ["UsageBarUpdateTestMode": true]
        #if DEBUG
        XCTAssertTrue(UpdateConfiguration.isIsolatedFixture(info: info, bundleIdentifier: fixtureID))
        #else
        XCTAssertFalse(UpdateConfiguration.isIsolatedFixture(info: info, bundleIdentifier: fixtureID))
        #endif
        XCTAssertFalse(UpdateConfiguration(info: info, bundleIdentifier: fixtureID, isDemo: true,
                                           allowsLocalFixture: true).isReady)
        XCTAssertFalse(UpdateConfiguration.isIsolatedFixture(info: info, bundleIdentifier: productionID))
        XCTAssertFalse(UpdateConfiguration.isIsolatedFixture(info: [:], bundleIdentifier: fixtureID))
    }

    func testDisplayedVersionUsesBundleMetadataAndFallsBackForDevelopment() {
        XCTAssertEqual(UpdateConfiguration.displayVersion(info: ["CFBundleShortVersionString": "0.7.0",
                                                                 "CFBundleVersion": "42"]), "0.7.0 (42)")
        XCTAssertEqual(UpdateConfiguration.displayVersion(info: ["CFBundleShortVersionString": "0.7.0"]), "0.7.0")
        XCTAssertEqual(UpdateConfiguration.displayVersion(info: [:]), "개발 버전")
    }
}
