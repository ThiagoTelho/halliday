/// Called under the owner's lock. Tokens retire pending effects before a slow
/// output queue reaches them; a one-hand stop never cancels the other hand.
struct SenseOutputPolicy: Sendable {
    private(set) var focused = true
    private var revisions: [UInt64] = [0, 0]
    func token(hand: Int) -> UInt64 { revisions[hand] }
    func accepts(hand: Int, token: UInt64) -> Bool {
        revisions.indices.contains(hand) && revisions[hand] == token && focused
    }
    mutating func cancel(hand: Int) { if revisions.indices.contains(hand) { revisions[hand] &+= 1 } }
    mutating func cancelAll() { for hand in revisions.indices { cancel(hand: hand) } }
    @discardableResult mutating func setFocused(_ value: Bool) -> Bool {
        guard value != focused else { return false }
        focused = value; cancelAll(); return true
    }
}
