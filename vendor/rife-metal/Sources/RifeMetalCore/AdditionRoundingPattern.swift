// The reference inputs/results depend only on Float16 arithmetic, not device,
// model, image dimensions or OS graph behavior. GPU output is still checked on
// every new graph; only CPU reference generation is shared (496 KiB maximum).
#if arch(arm64)
struct AdditionRoundingPattern: Sendable {
    static let period = 0x7bff * 2
    let lhs: [UInt16]
    let rhs: [UInt16]
    let nearestEven: [UInt16]
    let nearestAway: [UInt16]
    private static let full = make(count: period)

    static func forCount(_ count: Int) -> Self {
        precondition(count > 0)
        // Small graphs avoid allocating/calculating the full cycle.
        return count >= period ? full : make(count: count)
    }

    private static func make(count: Int) -> Self {
        var lhs = [UInt16](repeating: 0, count: count)
        var rhs = [UInt16](repeating: 0, count: count)
        var nearestEven = [UInt16](repeating: 0, count: count)
        var nearestAway = [UInt16](repeating: 0, count: count)
        for i in 0..<count {
            lhs[i] = UInt16((i * 73) % 0x7bff) | (i.isMultiple(of: 2) ? 0x8000 : 0)
            rhs[i] = UInt16((i * 193 + 79) % 0x7bff) | (i.isMultiple(of: 3) ? 0x8000 : 0)
            let exact = Float(Float16(bitPattern: lhs[i])) + Float(Float16(bitPattern: rhs[i]))
            let even = Float16(exact).bitPattern
            var away = even
            let magnitude = abs(Float(Float16(bitPattern: even)))
            if magnitude < abs(exact), even & 0x7fff < 0x7bff {
                let next = Float(Float16(bitPattern: (even & 0x7fff) + 1))
                if abs(exact) == (magnitude + next) / 2 { away = even + 1 }
            }
            nearestEven[i] = even
            nearestAway[i] = away
        }
        return Self(lhs:lhs, rhs:rhs, nearestEven:nearestEven, nearestAway:nearestAway)
    }
}
#endif
