import Foundation
import Push
import XCTest

final class PushTokenEncodingTests: XCTestCase {
    func testEveryByteBecomesTwoLowercaseHexDigits() {
        XCTAssertEqual(PushTokenEncoding.hex(Data([0x00, 0x0f, 0xab, 0xff])), "000fabff")
    }
}
