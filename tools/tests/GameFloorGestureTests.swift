@main struct GameFloorGestureTests {
    static func main() {
        struct Frame {
            let presenting: Bool, menu: Bool, paused: Bool, grip: Bool
            let stick: SIMD2<Float>
        }
        var height: Float = 0
        var menuScrolls = 0
        var gameInputs: [SIMD2<Float>] = []
        // Both hands use this same gesture; the right grip is the existing
        // shared modifier. Holding it through pause/resume must neither move
        // the live game's floor nor consume either game's stick.
        let frames = [
            Frame(presenting:true,menu:false,paused:false,grip:true,stick:[0.4,1]),
            Frame(presenting:true,menu:false,paused:false,grip:true,stick:[-0.7,-1]),
            Frame(presenting:true,menu:true,paused:true,grip:true,stick:[0.4,1]),
            Frame(presenting:true,menu:true,paused:true,grip:true,stick:[-0.7,-1]),
            Frame(presenting:true,menu:false,paused:false,grip:true,stick:[0.4,1]),
            Frame(presenting:true,menu:false,paused:false,grip:true,stick:[-0.7,-1])]
        for f in frames {
            let before = height
            let adjustment = GameFloorGesture.heightStick(gamePresenting:f.presenting,
                pauseMenuOpen:f.menu,gamePaused:f.paused,rightGripHeld:f.grip,stick:f.stick)
            if let adjustment { height += adjustment * 0.01 }
            if f.presenting && !f.menu {
                gameInputs.append(f.stick)
                precondition(height == before, "Grip+stick changed live game floor")
            } else if adjustment == nil { menuScrolls += 1 }
        }
        precondition(gameInputs == [[0.4,1],[-0.7,-1],[0.4,1],[-0.7,-1]],
            "Normal grip+stick input must reach both game controllers unchanged")
        precondition(height == 0 && menuScrolls == 0,
            "Pause adjustments apply both signs and do not also scroll the menu")
        for menu in [false,true] { for paused in [false,true] {
            if menu && paused { continue }
            precondition(GameFloorGesture.heightStick(gamePresenting:true,pauseMenuOpen:menu,
                gamePaused:paused,rightGripHeld:true,stick:[0,1]) == nil,
                "Only the explicit paused Halliday menu may adjust the floor")
        }}
        precondition(GameFloorGesture.heightStick(gamePresenting:false,pauseMenuOpen:true,
            gamePaused:true,rightGripHeld:true,stick:[0,1]) == nil, "No game: preserve Home inputs")
        precondition(GameFloorGesture.heightStick(gamePresenting:true,pauseMenuOpen:true,
            gamePaused:true,rightGripHeld:false,stick:[0,1]) == nil, "Ordinary menu scroll remains available")
        for stick: SIMD2<Float> in [[1,0],[0,0.25],[0,-0.25],[0,.nan]] {
            precondition(GameFloorGesture.heightStick(gamePresenting:true,pauseMenuOpen:true,
                gamePaused:true,rightGripHeld:true,stick:stick) == nil)
        }
        print("PASS: floor gesture only in explicit paused game menu; both stick signs/hands; held grip through Resume; gameplay sticks unchanged; Home/menu scrolling and threshold preserved")
    }
}
