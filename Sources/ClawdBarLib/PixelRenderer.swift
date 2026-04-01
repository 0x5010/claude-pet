import AppKit
import ClawdBarCore

public struct PixelRenderer {
    static let bodyColor = NSColor(red: 0xDE/255.0, green: 0x88/255.0, blue: 0x6D/255.0, alpha: 1)
    static let errorColor = NSColor(red: 0xE0/255.0, green: 0x5A/255.0, blue: 0x4A/255.0, alpha: 1)
    static let eyeColor = NSColor.black
    static let laptopScreen = NSColor(red: 0x78/255.0, green: 0x90/255.0, blue: 0x9C/255.0, alpha: 1)
    static let laptopBase = NSColor(red: 0x54/255.0, green: 0x6E/255.0, blue: 0x7A/255.0, alpha: 1)
    static let shadowColor = NSColor(white: 0, alpha: 0.4)

    // Grid & rendering constants (3x original 15×12)
    static let gridWidth = 45
    static let gridHeight = 36
    static let imageSize: CGFloat = 22
    static let pixelScale: CGFloat = 0.5  // 1 logical pixel = 0.5pt = 1 Retina physical pixel

    // Body-centered coordinates (3x of original):
    //   Torso:  x:6  y:6  w:33 h:21
    //   Legs:   y:21-33
    //   Arms:   y:15-21
    //   Eyes:   y:12-18
    //   Shadow: y:33

    public static func render(state: PetState, frame: Int, totalFrames: Int) -> NSImage {
        let size = NSSize(width: imageSize, height: imageSize)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)

        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none

        let scale = pixelScale
        let offsetX: CGFloat = (imageSize - CGFloat(gridWidth) * scale) / 2   // -0.25
        let offsetY: CGFloat = (imageSize - CGFloat(gridHeight) * scale) / 2  // 2.0

        func px(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            NSRect(x: offsetX + CGFloat(x) * scale,
                   y: offsetY + CGFloat(y) * scale,
                   width: CGFloat(w) * scale,
                   height: CGFloat(h) * scale).fill()
        }

        switch state {
        case .idle:
            drawIdle(px: px, frame: frame)
        case .thinking:
            drawThinking(px: px, frame: frame)
        case .working:
            drawWorking(px: px, frame: frame)
        case .error:
            drawError(px: px, frame: frame)
        case .juggling:
            drawJuggling(px: px, frame: frame)
        case .notification:
            drawNotification(px: px, frame: frame)
        case .happy:
            drawHappy(px: px, frame: frame)
        case .sleeping:
            drawSleeping(px: px, frame: frame)
        }

        image.unlockFocus()
        return image
    }

    // MARK: - Shared body (3x coordinates)

    static func drawBody(px: (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void,
                         bodyFill: NSColor = bodyColor, yOff: Int = 0) {
        // Shadow
        shadowColor.setFill()
        px(9, 33 + yOff, 27, 3)
        // Legs
        bodyFill.setFill()
        px(9, 21 + yOff, 3, 12); px(15, 21 + yOff, 3, 12)
        px(27, 21 + yOff, 3, 12); px(33, 21 + yOff, 3, 12)
        // Torso
        px(6, 6 + yOff, 33, 21)
        // Arms
        px(0, 15 + yOff, 6, 6); px(39, 15 + yOff, 6, 6)
    }

    static func drawEyes(px: (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void,
                         yOff: Int = 0, height: Int = 6) {
        eyeColor.setFill()
        px(12, 12 + yOff, 3, height); px(30, 12 + yOff, 3, height)
    }

    // MARK: - Idle: breathe + blink

    static func drawIdle(px: @escaping (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void, frame: Int) {
        drawBody(px: px)
        // Blink on frame 3 and 4
        if frame == 3 || frame == 4 {
            eyeColor.setFill()
            px(12, 15, 3, 3); px(30, 15, 3, 3) // half-height = blink
        } else {
            drawEyes(px: px)
        }
    }

    // MARK: - Thinking (legacy): sway + dots above head

    static func drawThinkingLegacy(px: @escaping (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void,
                              frame: Int, totalFrames: Int) {
        drawBody(px: px)
        // Eyes looking up (shifted up 3px)
        eyeColor.setFill()
        px(12, 9, 3, 6); px(30, 9, 3, 6)
        // Loading dots above head — sequential
        let dotColor = NSColor(red: 0xB0/255.0, green: 0x5E/255.0, blue: 0x44/255.0, alpha: 1)
        dotColor.setFill()
        let phase = frame % totalFrames
        if phase >= 1 { px(12, 0, 6, 3) }
        if phase >= 2 { px(21, 0, 6, 3) }
        if phase >= 3 { px(30, 0, 6, 3) }
        // Dot "bounce" — redraw the latest dot 3px higher on its appear frame
        if phase == 1 { dotColor.setFill(); px(12, -3, 6, 3) }
        if phase == 2 { dotColor.setFill(); px(21, -3, 6, 3) }
        if phase == 3 { dotColor.setFill(); px(30, -3, 6, 3) }
    }

    // MARK: - Working: full body behind laptop, arms typing, squint eyes scanning, data particles

    static func drawWorking(px: @escaping (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void, frame: Int) {
        let jitterY = (frame % 2 == 0) ? 0 : -3

        // Data particles floating up from behind laptop (#40C4FF)
        let particlePositions: [(Int, Int, Int)] = [  // (x, startY, delay)
            (0, 24, 0), (12, 24, 2), (24, 24, 4), (36, 24, 1), (18, 24, 3), (42, 24, 5)
        ]
        for (px2, startY, delay) in particlePositions {
            let phase = (frame + delay) % 8
            if phase < 7 {
                let y = startY - phase * 6  // faster rise
                let alpha = phase < 4 ? 1.0 : max(0.3, 1.0 - Double(phase - 4) * 0.3)
                NSColor(red: 0x40/255.0, green: 0xC4/255.0, blue: 0xFF/255.0, alpha: alpha).setFill()
                px(px2, y, 6, 3)
            }
        }

        // Full body with legs (behind laptop)
        shadowColor.setFill()
        px(9, 33, 27, 3)
        bodyColor.setFill()
        // Legs
        px(9, 21 + jitterY, 3, 12); px(15, 21 + jitterY, 3, 12)
        px(27, 21 + jitterY, 3, 12); px(33, 21 + jitterY, 3, 12)
        // Torso
        px(6, 6 + jitterY, 33, 21)
        // Arms pointing forward (toward keyboard) — lower position
        px(0, 21 + jitterY, 6, 3); px(39, 21 + jitterY, 6, 3)

        // Squint eyes (half height) scanning left-right
        let eyeOffsets = [-3, 0, 3, 3, 0, -3]
        let eyeOff = eyeOffsets[frame % eyeOffsets.count]
        eyeColor.setFill()
        px(12 + eyeOff, 15 + jitterY, 3, 3); px(30 + eyeOff, 15 + jitterY, 3, 3)

        // Laptop in front (covers legs) — screen back + base + glowing logo
        laptopScreen.setFill()
        px(9, 18, 27, 15)
        laptopBase.setFill()
        px(6, 33, 33, 3)
        // Glowing logo
        let logoAlpha = (frame % 3 == 0) ? 1.0 : 0.4
        NSColor(white: 1, alpha: logoAlpha).setFill()
        px(21, 24, 3, 3)
    }

    // MARK: - Error: shake + flash red + XX eyes

    static func drawError(px: @escaping (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void, frame: Int) {
        let flashRed = (frame % 2 == 0)
        drawBody(px: px, bodyFill: flashRed ? errorColor : bodyColor)
        // x x eyes
        eyeColor.setFill()
        // Left x
        px(9, 9, 3, 3); px(15, 9, 3, 3)
        px(12, 12, 3, 3)
        px(9, 15, 3, 3); px(15, 15, 3, 3)
        // Right x
        px(27, 9, 3, 3); px(33, 9, 3, 3)
        px(30, 12, 3, 3)
        px(27, 15, 3, 3); px(33, 15, 3, 3)
    }

    // MARK: - Sleeping: standing body without legs + closed eyes + Z

    static func drawSleeping(px: @escaping (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void, frame: Int) {
        // Shadow
        shadowColor.setFill()
        px(6, 33, 33, 3)

        // Body on ground (no legs)
        bodyColor.setFill()
        px(6, 12, 33, 21)      // torso (shifted down)
        px(0, 21, 6, 6)        // left arm
        px(39, 21, 6, 6)       // right arm

        // Closed eyes (horizontal lines)
        eyeColor.setFill()
        px(9, 21, 9, 3); px(27, 21, 9, 3)

        // Sleep bubble — rises from right forehead toward upper-right, loops
        let startX = 33, startY = 9   // near right forehead
        let endX = 42, endY = 0       // upper-right corner
        let phase = frame % 6
        // Interpolate position along path
        let t = Double(phase) / 5.0
        let bx = startX + Int(Double(endX - startX) * t)
        let by = startY + Int(Double(endY - startY) * t)
        // Size grows as it rises: 3→6
        let bSize = phase < 3 ? 3 : 6
        // Fade out near end
        let alpha = phase < 4 ? 0.7 : (phase < 5 ? 0.5 : 0.3)
        NSColor(white: 0.6, alpha: alpha).setFill()
        px(bx, by, bSize, bSize)
    }

    // MARK: - Juggling: body sway + orbiting dots (subagent multitasking)

    static func drawJuggling(px: @escaping (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void, frame: Int) {
        // Shadow stays fixed but wider to cover rock range
        shadowColor.setFill()
        px(6, 33, 33, 3)
        // Body rocks left-right
        let rockX = [-3, 0, 3, 0][frame % 4]
        let rockBody: (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void = { x, y, w, h in px(x + rockX, y, w, h) }
        bodyColor.setFill()
        rockBody(9, 21, 3, 12); rockBody(15, 21, 3, 12)
        rockBody(27, 21, 3, 12); rockBody(33, 21, 3, 12)
        rockBody(6, 6, 33, 21)
        rockBody(0, 15, 6, 6); rockBody(39, 15, 6, 6)
        // Eyes
        eyeColor.setFill()
        rockBody(12, 12, 3, 6); rockBody(30, 12, 3, 6)

        // Juggling arc (3x positions)
        let arc: [(Int, Int)] = [
            (0, 21),   // left hand
            (6, 9),    // rising
            (12, 0),   // near top
            (21, -6),  // apex
            (30, 0),   // descending
            (36, 9),   // falling
            (42, 21),  // right hand
            (21, 12),  // return (underneath)
        ]
        let colors: [NSColor] = [
            NSColor(red: 0xFF/255.0, green: 0x52/255.0, blue: 0x52/255.0, alpha: 1),
            NSColor(red: 0xFF/255.0, green: 0xC1/255.0, blue: 0x07/255.0, alpha: 1),
            NSColor(red: 0x4C/255.0, green: 0xAF/255.0, blue: 0x50/255.0, alpha: 1),
        ]
        for i in 0..<3 {
            let idx = (frame + i * 3) % arc.count
            let p = arc[idx]
            colors[i].setFill()
            px(p.0, p.1, 6, 6)
        }
    }

    // MARK: - Notification: body + blinking exclamation

    static func drawNotification(px: @escaping (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void, frame: Int) {
        // Rapid jumping — fast bounce
        let jumpY = [0, -6, 0, -6][frame % 4]

        // Shadow shrinks when airborne
        shadowColor.setFill()
        if jumpY == 0 { px(9, 33, 27, 3) } else { px(12, 33, 21, 3) }

        // Body (normal color, jumps)
        bodyColor.setFill()
        px(9, 21 + jumpY, 3, 12); px(15, 21 + jumpY, 3, 12)
        px(27, 21 + jumpY, 3, 12); px(33, 21 + jumpY, 3, 12)
        px(6, 6 + jumpY, 33, 21)
        px(0, 15 + jumpY, 6, 6); px(39, 15 + jumpY, 6, 6)

        // Normal eyes
        eyeColor.setFill()
        px(12, 12 + jumpY, 3, 6); px(30, 12 + jumpY, 3, 6)
    }

    // MARK: - Happy: body + smile + sparkles

    static func drawHappy(px: @escaping (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void, frame: Int) {
        // Bounce: body hops up on frames 2-3
        let bounceY = [0, 0, -3, -6, -3, 0][frame % 6]

        // Shadow shrinks when bouncing
        shadowColor.setFill()
        if bounceY == 0 {
            px(9, 33, 27, 3)
        } else {
            px(12, 33, 21, 3)
        }

        // Body (draw manually, skip drawBody shadow)
        bodyColor.setFill()
        px(9, 21 + bounceY, 3, 12); px(15, 21 + bounceY, 3, 12)
        px(27, 21 + bounceY, 3, 12); px(33, 21 + bounceY, 3, 12)
        px(6, 6 + bounceY, 33, 21)
        px(0, 15 + bounceY, 6, 6); px(39, 15 + bounceY, 6, 6)

        // Happy curved eyes (^ ^)
        eyeColor.setFill()
        px(9, 12 + bounceY, 3, 3); px(12, 9 + bounceY, 3, 3); px(15, 12 + bounceY, 3, 3)
        px(27, 12 + bounceY, 3, 3); px(30, 9 + bounceY, 3, 3); px(33, 12 + bounceY, 3, 3)

        // Pixel-art cross sparkles — 3 sparkles at staggered phases
        let sparklePositions: [(Int, Int, Int)] = [(0, 0, 0), (39, -3, 2), (18, -6, 4)]
        let sparkleColors: [NSColor] = [
            NSColor(red: 0xFF/255.0, green: 0xD7/255.0, blue: 0x00/255.0, alpha: 1),
            NSColor(red: 0xFF/255.0, green: 0xA0/255.0, blue: 0x00/255.0, alpha: 1),
            NSColor(red: 0xFF/255.0, green: 0xF5/255.0, blue: 0x9D/255.0, alpha: 1),
        ]
        for (i, (sx, sy, delay)) in sparklePositions.enumerated() {
            let phase = (frame + delay) % 6
            sparkleColors[i].setFill()
            if phase == 0 || phase == 1 {
                px(sx + 3, sy + 3, 3, 3)
            }
            if phase == 1 || phase == 2 {
                px(sx + 3, sy + 3, 3, 3) // center
                px(sx + 3, sy, 3, 3)     // top
                px(sx + 3, sy + 6, 3, 3) // bottom
                px(sx, sy + 3, 3, 3)     // left
                px(sx + 6, sy + 3, 3, 3) // right
            }
        }
    }

    // MARK: - Thinking: headphones + swaying body + floating notes + closed eyes

    static func drawThinking(px: @escaping (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void, frame: Int) {
        // Body sways left-right with slight bounce
        let swayPattern = [-3, -3, 0, 3, 3, 3, 0, -3]
        let bouncePattern = [0, -3, -3, 0, 0, -3, -3, 0]
        let swayX = swayPattern[frame % swayPattern.count]
        let bounceY = bouncePattern[frame % bouncePattern.count]

        let sway: (_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Void = { x, y, w, h in
            px(x + swayX, y + bounceY, w, h)
        }

        // Shadow stays fixed
        shadowColor.setFill()
        px(6, 33, 33, 3)

        // Body
        bodyColor.setFill()
        // Legs
        sway(9, 21, 3, 12); sway(15, 21, 3, 12)
        sway(27, 21, 3, 12); sway(33, 21, 3, 12)
        // Torso
        sway(6, 6, 33, 21)
        // Arms — waving to the rhythm (alternate sides up/down)
        let armPhase = frame % 4
        let leftArmY = armPhase < 2 ? 12 : 15
        let rightArmY = armPhase < 2 ? 15 : 12
        sway(0, leftArmY, 6, 6)
        sway(39, rightArmY, 6, 6)

        // Closed eyes — horizontal lines (content/relaxed, different from happy ^ ^)
        eyeColor.setFill()
        sway(9, 15, 9, 3); sway(27, 15, 9, 3)

        // Headphones — dark band + ear cups
        let hpColor = NSColor(red: 0x1b/255.0, green: 0x4d/255.0, blue: 0x80/255.0, alpha: 1)
        hpColor.setFill()
        // Headband — arch sitting on top of ear cups
        sway(3, 3, 3, 3)     // left drop
        sway(6, 0, 33, 3)    // main arch
        sway(39, 3, 3, 3)    // right drop
        // Left ear cup (outer side shorter)
        sway(0, 6, 3, 6)     // outer edge (shorter)
        sway(3, 6, 3, 9)     // inner edge (full height)
        // Right ear cup (outer side shorter)
        sway(39, 6, 3, 9)    // inner edge (full height)
        sway(42, 6, 3, 6)    // outer edge (shorter)

        // Floating music notes — rise from above head into upper corners
        // Note shape: ♪ = filled head (3x3) + stem (3x6) + flag (3x3)
        //   ##
        //   #
        //   #
        //  ##

        // Note 1: rises from upper-left (purple)
        let n1Phase = frame % 8
        if n1Phase < 7 {
            let ny = -3 - n1Phase * 2  // start just above headband, rise slowly
            let nx = 3 - n1Phase       // drift left
            let alpha = n1Phase < 4 ? 1.0 : max(0.2, 1.0 - Double(n1Phase - 3) * 0.25)
            NSColor(red: 0x7C/255.0, green: 0x4D/255.0, blue: 0xFF/255.0, alpha: alpha).setFill()
            px(nx, ny + 6, 3, 3)       // note head
            px(nx + 3, ny, 3, 6)       // stem
            px(nx + 6, ny, 3, 3)       // flag
        }

        // Note 2: rises from upper-right (pink, offset by 4 frames)
        let n2Phase = (frame + 4) % 8
        if n2Phase < 7 {
            let ny = -3 - n2Phase * 2
            let nx = 36 + n2Phase      // drift right
            let alpha = n2Phase < 4 ? 1.0 : max(0.2, 1.0 - Double(n2Phase - 3) * 0.25)
            NSColor(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x9D/255.0, alpha: alpha).setFill()
            px(nx, ny + 6, 3, 3)
            px(nx + 3, ny, 3, 6)
            px(nx + 6, ny, 3, 3)
        }
    }
}
