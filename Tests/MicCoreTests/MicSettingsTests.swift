import Foundation
import XCTest
@testable import MicCore

final class MicSettingsTests: XCTestCase {
    func testLegacyConfigurationUsesPlatformDefaults() throws {
        let data = Data(#"{"outputID":"device","outputName":"CABLE Input","aiKeyMap":163}"#.utf8)
        let settings = try JSONDecoder().decode(MicSettings.self, from: data)
        XCTAssertEqual(settings.aiKeyMap, 163)
        XCTAssertEqual(settings.mode, .auto)
        XCTAssertFalse(settings.mode.usesPushToTalk(isBluetooth: false))
        #if os(Windows)
        XCTAssertFalse(settings.mode.usesPushToTalk(isBluetooth: true))
        #else
        XCTAssertTrue(settings.mode.usesPushToTalk(isBluetooth: true))
        #endif
    }

    func testLegacyConfigurationWithoutMappingRemainsUnmapped() throws {
        let data = Data(#"{"outputID":"device","outputName":"BlackHole"}"#.utf8)
        let settings = try JSONDecoder().decode(MicSettings.self, from: data)
        XCTAssertNil(settings.aiKeyMap)
        XCTAssertEqual(settings.mode, .auto)
    }

    func testExplicitModesApplyToBothTransports() {
        for isBluetooth in [false, true] {
            XCTAssertFalse(MicMode.alwaysOn.usesPushToTalk(isBluetooth: isBluetooth))
            XCTAssertTrue(MicMode.pushToTalk.usesPushToTalk(isBluetooth: isBluetooth))
        }
    }

    func testConfigurationRoundTripPreservesModeAndMapping() throws {
        for mode in [MicMode.auto, .alwaysOn, .pushToTalk] {
            let settings = MicSettings(outputID: "stable-device-id", outputName: "BlackHole",
                                       aiKeyMap: 63, mode: mode)
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(MicSettings.self, from: data), settings)
        }
    }

    func testUnknownModeIsRejectedInsteadOfOpeningMicrophone() {
        let data = Data(#"{"outputID":"device","outputName":"BlackHole","mode":"invalid"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MicSettings.self, from: data))
    }
}
