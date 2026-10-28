import Foundation
import Testing
@testable import Outbound

/// The ground cache's window moves on a band at a time, and always holds what the view needs.
@MainActor
@Suite
struct GroundAheadTests {
    @Test func theViewAlwaysLiesInsideAndTheWindowMovesRarely() {
        let room = (x: ViewRenderer.ahead, y: ViewRenderer.ahead)
        var valid: (x: Int, y: Int)? = nil
        var moves = 0
        // A slow pan up, about a texel a frame, with a sideways drift that turns back now and then.
        for frame in 0..<3000 {
            let view = (x: Int((40 * sin(Double(frame) / 300)).rounded(.down)), y: frame)
            let window = ViewRenderer.window(for: view, from: valid, room: room)
            #expect(window.x <= view.x && view.x <= window.x + room.x)
            #expect(window.y <= view.y && view.y <= window.y + room.y)
            if let valid, window != valid { moves += 1 }
            valid = window
        }
        // Moving up, all the room is ahead: one move every sixteen rows or so, not every frame.
        #expect(moves < 3000 / 12)
        #expect(moves > 3000 / 40)
        // A jump lands the view against the side it came from.
        let jumped = ViewRenderer.window(for: (x: 500, y: 10_000), from: (x: 0, y: 0), room: room)
        #expect(jumped.y == 10_000 && jumped.x == 500)
        let back = ViewRenderer.window(for: (x: -500, y: -10_000), from: (x: 0, y: 0), room: room)
        #expect(back.y == -10_000 - room.y && back.x == -500 - room.x)
    }
}
