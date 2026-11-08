import Foundation

/// Swift port of the npm `fractional-indexing` package (default base-62 digits, base-52 integer heads),
/// so keys made on the Mac sort exactly like keys made by the backend. Keys compare bytewise.
public enum FractionalIndex {
    public struct KeyError: Error, CustomStringConvertible {
        public let description: String
    }

    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    static let intDigits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    static let lookup: [Int] = table(digits)
    static let intLookup: [Int] = table(intDigits)

    private static func table(_ d: [UInt8]) -> [Int] {
        var t = [Int](repeating: -1, count: 256)
        for (i, c) in d.enumerated() { t[Int(c)] = i }
        return t
    }

    /// A key strictly between `a` and `b` (either may be nil for open ends). Order of a and b does not matter.
    public static func between(_ a: String?, _ b: String?) throws -> String {
        var a = a.map { Array($0.utf8) }
        var b = b.map { Array($0.utf8) }
        if let x = a { try validate(x) }
        if let y = b { try validate(y) }
        if let x = a, let y = b, x.lexicographicallyPrecedes(y) == false, x != y { (a, b) = (y, x) }

        guard let a else {
            guard let b else { return str([intDigits[intDigits.count / 2], digits[0]]) }
            let ib = try integerPart(b)
            let fb = Array(b[ib.count...])
            if isSmallestInteger(ib) { return str(ib + (try midpoint([], fb))) }
            if ib.lexicographicallyPrecedes(b) { return str(ib) }
            guard let res = try decrement(ib) else { throw KeyError(description: "cannot decrement any more") }
            return str(res)
        }
        guard let b else {
            let ia = try integerPart(a)
            let fa = Array(a[ia.count...])
            if let i = try increment(ia) { return str(i) }
            return str(ia + (try midpoint(fa, nil)))
        }
        let ia = try integerPart(a)
        let fa = Array(a[ia.count...])
        let ib = try integerPart(b)
        let fb = Array(b[ib.count...])
        if ia == ib { return str(ia + (try midpoint(fa, fb))) }
        guard let i = try increment(ia) else { throw KeyError(description: "cannot increment any more") }
        if i.lexicographicallyPrecedes(b) { return str(i) }
        return str(ia + (try midpoint(fa, nil)))
    }

    /// `n` ascending keys strictly between `a` and `b`.
    public static func keys(between a: String?, and b: String?, count n: Int) throws -> [String] {
        var out: [String] = []
        var prev = a
        for _ in 0..<n {
            let k = try between(prev, b)
            out.append(k)
            prev = k
        }
        return out
    }

    private static func str(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) throws -> [UInt8] {
        let zero = digits[0]
        if let b, !a.lexicographicallyPrecedes(b) { throw KeyError(description: "midpoint: a >= b") }
        if a.last == zero || (b?.last == zero) { throw KeyError(description: "trailing zero") }
        if let b {
            var n = 0
            while n < b.count && (n < a.count ? a[n] : zero) == b[n] { n += 1 }
            if n > 0 { return Array(b[0..<n]) + (try midpoint(Array(a.dropFirst(min(n, a.count))), Array(b[n...]))) }
        }
        let digitA = a.isEmpty ? 0 : lookup[Int(a[0])]
        let digitB = b.map { lookup[Int($0[0])] } ?? digits.count
        if digitB - digitA > 1 {
            let mid = Int((0.5 * Double(digitA + digitB)).rounded(.toNearestOrAwayFromZero))
            return [digits[mid]]
        }
        if let b, b.count > 1 { return [b[0]] }
        return [digits[digitA]] + (try midpoint(Array(a.dropFirst()), nil))
    }

    private static func integerLength(_ head: UInt8) throws -> Int {
        let i = intLookup[Int(head)]
        guard i >= 0 else { throw KeyError(description: "invalid order key head") }
        let half = intDigits.count / 2
        return i < half ? half - i + 1 : i - half + 2
    }

    private static func integerPart(_ key: [UInt8]) throws -> [UInt8] {
        guard let head = key.first else { throw KeyError(description: "empty key") }
        let len = try integerLength(head)
        guard len <= key.count else { throw KeyError(description: "invalid order key") }
        return Array(key[0..<len])
    }

    private static func isSmallestInteger(_ key: [UInt8]) -> Bool {
        key == [intDigits[0]] + [UInt8](repeating: digits[0], count: intDigits.count / 2)
    }

    private static func validate(_ key: [UInt8]) throws {
        if isSmallestInteger(key) { throw KeyError(description: "invalid order key") }
        let i = try integerPart(key)
        if key.count > i.count && key.last == digits[0] { throw KeyError(description: "invalid order key") }
        for c in key where lookup[Int(c)] < 0 { throw KeyError(description: "invalid character in key") }
    }

    private static func increment(_ x: [UInt8]) throws -> [UInt8]? {
        let head = x[0]
        var trailing: [UInt8] = []
        var i = x.count - 1
        while i >= 1 {
            let d = lookup[Int(x[i])] + 1
            if d == digits.count { trailing.insert(digits[0], at: 0) } else { return [head] + Array(x[1..<i]) + [digits[d]] + trailing }
            i -= 1
        }
        let headIndex = intLookup[Int(head)]
        if headIndex == intDigits.count - 1 { return nil }
        let h = intDigits[headIndex + 1]
        let delta = try integerLength(h) - (try integerLength(head))
        if delta > 0 { return [h] + trailing + [digits[0]] }
        if delta < 0 { return [h] + Array(trailing.dropFirst()) }
        return [h] + trailing
    }

    private static func decrement(_ x: [UInt8]) throws -> [UInt8]? {
        let head = x[0]
        let last = digits[digits.count - 1]
        var trailing: [UInt8] = []
        var i = x.count - 1
        while i >= 1 {
            let d = lookup[Int(x[i])] - 1
            if d == -1 { trailing.insert(last, at: 0) } else { return [head] + Array(x[1..<i]) + [digits[d]] + trailing }
            i -= 1
        }
        let headIndex = intLookup[Int(head)]
        if headIndex == 0 { return nil }
        let h = intDigits[headIndex - 1]
        let delta = try integerLength(h) - (try integerLength(head))
        if delta > 0 { return [h] + trailing + [last] }
        if delta < 0 { return [h] + Array(trailing.dropFirst()) }
        return [h] + trailing
    }
}
