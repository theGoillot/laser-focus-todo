import XCTest
@testable import TodoCore

/// Vectors generated from the npm `fractional-indexing` package the backend uses, so both sides sort the same.
final class FractionalIndexTests: XCTestCase {
    func testMatchesJavaScriptVectors() throws {
        let cases: [(String?, String?, String)] = [
            (nil, nil, "a0"),
            (nil, "a0", "Zz"),
            ("a0", nil, "a1"),
            ("a0", "a1", "a0V"),
            ("a0", "a0V", "a0G"),
            ("a1", "a2", "a1V"),
            ("a0V", "a1", "a0l"),
            (nil, "a0V", "a0"),
            ("Zz", "a0", "ZzV"),
            ("a0", "a01", "a00V"),
            ("az", nil, "b00"),
            ("zzzzzzzzzzzzzzzzzzzzzzzzzzz", nil, "zzzzzzzzzzzzzzzzzzzzzzzzzzzV"),
            (nil, "A00000000000000000000000001", "A00000000000000000000000000"),
            ("a0", "a0G", "a08"),
            ("b00", nil, "b01"),
            ("a1", nil, "a2"),
            ("Zy", "Zz", "ZyV")
        ]
        for (a, b, expected) in cases {
            XCTAssertEqual(try FractionalIndex.between(a, b), expected, "between(\(a ?? "nil"), \(b ?? "nil"))")
        }
    }

    func testAppendSequenceMatches() throws {
        let expected = ["a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "aA", "aB", "aC", "aD", "aE", "aF", "aG", "aH", "aI", "aJ", "aK", "aL", "aM", "aN", "aO", "aP", "aQ", "aR", "aS", "aT", "aU", "aV", "aW", "aX", "aY", "aZ", "aa", "ab", "ac", "ad", "ae", "af", "ag", "ah", "ai", "aj", "ak", "al", "am", "an", "ao", "ap", "aq", "ar", "as", "at", "au", "av", "aw", "ax", "ay", "az", "b00", "b01", "b02", "b03", "b04", "b05", "b06", "b07"]
        var key: String? = nil
        for e in expected {
            key = try FractionalIndex.between(key, nil)
            XCTAssertEqual(key, e)
        }
    }

    func testRepeatedBisectionMatches() throws {
        let expected = ["a0V", "a0G", "a08", "a04", "a02", "a01", "a00V", "a00G", "a008", "a004", "a002", "a001", "a000V", "a000G", "a0008", "a0004", "a0002", "a0001", "a0000V", "a0000G", "a00008", "a00004", "a00002", "a00001", "a00000V", "a00000G", "a000008", "a000004", "a000002", "a000001"]
        var hi = "a1"
        for e in expected {
            let m = try FractionalIndex.between("a0", hi)
            XCTAssertEqual(m, e)
            hi = m
        }
    }

    func testKeysSortBytewise() throws {
        let a = try FractionalIndex.between(nil, nil)
        let b = try FractionalIndex.between(a, nil)
        let m = try FractionalIndex.between(a, b)
        XCTAssertTrue(a < m && m < b)
    }
}
