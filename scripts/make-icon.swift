// Renders the app icon into an .iconset folder. Usage: swift scripts/make-icon.swift <out.iconset>
//
// 16-bit style pixel art on a 64x64 grid: a chrome robot in wraparound shades, red rays behind it,
// and its lenses glowing with the lines of a script. Each grid pixel becomes a hard-edged block.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// MARK: Palette

struct RGB { var r, g, b: UInt8 }
func hex(_ v: UInt32) -> RGB { RGB(r: UInt8(v >> 16 & 255), g: UInt8(v >> 8 & 255), b: UInt8(v & 255)) }

let outline = hex(0x07070A)
let bgTop = hex(0x1A0507), bgBottom = hex(0x040404)
let rayBright = hex(0xD6141C), rayDark = hex(0x6A080C)
let steel = [hex(0x2B313B), hex(0x4F5968), hex(0x7F8B9C), hex(0xB4BFCC), hex(0xEEF3F8)]   // dark ... highlight
let lensDark = hex(0x2A0204), lensLine = hex(0xFF3B3B), lensDim = hex(0x9A1014), glare = hex(0xFFB3B3)
let frame = hex(0x15161A), frameHi = hex(0x3A3D45)
let titleRed = hex(0xE8121A), titleShadow = hex(0x4A0507)
let leather = hex(0x19191E), leatherHi = hex(0x3C3E47), leatherShine = hex(0x6A6D78)

// MARK: Canvas

let n = 64
var grid = [RGB?](repeating: nil, count: n * n)
func set(_ x: Int, _ y: Int, _ c: RGB) { if x >= 0, y >= 0, x < n, y < n { grid[y * n + x] = c } }
func get(_ x: Int, _ y: Int) -> RGB? { x >= 0 && y >= 0 && x < n && y < n ? grid[y * n + x] : nil }

/// macOS-style rounded square, stepped like a sprite: x/y 6...57 with a 12-pixel corner.
func inBody(_ x: Int, _ y: Int) -> Bool {
    let lo = 6, hi = 57, r = 12
    guard x >= lo, x <= hi, y >= lo, y <= hi else { return false }
    let cx = x < lo + r ? lo + r : (x > hi - r ? hi - r : x)
    let cy = y < lo + r ? lo + r : (y > hi - r ? hi - r : y)
    let dx = Double(x - cx), dy = Double(y - cy)
    return dx * dx + dy * dy <= Double(r * r) + 2
}

// Background: dark red at the top fading to black, in hard 4-pixel bands.
for y in 0..<n {
    for x in 0..<n where inBody(x, y) {
        let t = Double((y - 6) / 4 * 4) / 52
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(Double(a) * (1 - t) + Double(b) * t) }
        set(x, y, RGB(r: mix(bgTop.r, bgBottom.r), g: mix(bgTop.g, bgBottom.g), b: mix(bgTop.b, bgBottom.b)))
    }
}

// Rays fanning out from behind the head, like the poster's laser lines.
let center = (x: 32.0, y: 33.0)
for (i, degrees) in [-28.0, -14, -2, 9, 21, 159, 171, 182, 194, 208].enumerated() {
    let a = degrees * .pi / 180
    var r = 10.0
    while r < 60 {
        let x = Int((center.x + cos(a) * r).rounded()), y = Int((center.y - sin(a) * r).rounded())
        if inBody(x, y) { set(x, y, i % 2 == 0 ? rayBright : rayDark) }
        r += 0.5
    }
}

// Title across the top in a 3x5 pixel font.
let glyphs: [Character: [String]] = [
    "S": ["111", "100", "111", "001", "111"], "C": ["111", "100", "100", "100", "111"],
    "R": ["110", "101", "110", "101", "101"], "O": ["111", "101", "101", "101", "111"],
    "L": ["100", "100", "100", "100", "111"], "I": ["111", "010", "010", "010", "111"],
    "N": ["110", "101", "101", "101", "101"], "A": ["010", "101", "111", "101", "101"],
    "T": ["111", "010", "010", "010", "010"],
]
let title = "SCROLLINATOR"
var tx = (n - (title.count * 4 - 1)) / 2
for ch in title {
    for (row, bits) in glyphs[ch]!.enumerated() {
        for (col, bit) in bits.enumerated() where bit == "1" {
            set(tx + col + 1, 10 + row + 1, titleShadow)
            set(tx + col, 10 + row, titleRed)
        }
    }
    tx += 4
}

// MARK: Robot

// Leather jacket: shoulders across the bottom with a collar opening around the neck.
var jacket = [Bool](repeating: false, count: n * n)
for y in 49...57 {
    let half = 14 + (y - 49) * 2
    for x in (32 - half)...(31 + half) where inBody(x, y) {
        let dx = abs(Double(x) - 31.5)
        if dx < 6.5 - Double(y - 49) * 0.4 { continue }   // the open collar shows the neck
        jacket[y * n + x] = true
        let lapel = dx < 11 - Double(y - 49) * 0.2
        set(x, y, lapel ? leatherHi : leather)
    }
}
for (x, y) in [(14, 54), (15, 53), (16, 52), (48, 54), (47, 53), (46, 52), (24, 51), (39, 51)] { set(x, y, leatherShine) }

var head = [Bool](repeating: false, count: n * n)
var tone = [Int](repeating: 0, count: n * n)
func headAt(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < n && y < n && head[y * n + x] }

for y in 0..<n {
    for x in 0..<n {
        let dx = Double(x) - 31.5, dy = Double(y) - 31.0
        let cranium = y <= 36 && (dx * dx) / (12.5 * 12.5) + (dy * dy) / (13.0 * 13.0) <= 1
        // Jaw narrows from the cheekbones to the chin.
        let jawHalf = 11.5 - Double(max(0, y - 34)) * 0.33
        let jaw = y >= 33 && y <= 50 && abs(dx) <= jawHalf
        let neck = y >= 50 && y <= 57 && abs(dx) <= 5 && !jacket[y * n + x]
        guard cranium || jaw || neck else { continue }
        head[y * n + x] = true
        // Light from the top left, quantized into steel tones.
        let light = -dx / 13 * 0.55 - dy / 14 * 0.45
        tone[y * n + x] = neck ? (x % 2 == 0 ? 0 : 1) : min(3, max(0, Int((light + 0.9) * 2.1)))
    }
}
for y in 0..<n {
    for x in 0..<n where headAt(x, y) { set(x, y, steel[tone[y * n + x]]) }
}
// Highlight on the dome.
for (x, y) in [(25, 21), (26, 21), (27, 21), (24, 22), (25, 22), (26, 22), (24, 23), (25, 23), (23, 24)] {
    set(x, y, steel[4])
}
// Panel seams down the cheeks, a nose, and a grill mouth.
for y in 36...44 { set(22, y, steel[0]); set(41, y, steel[0]) }
for (x, y) in [(31, 37), (32, 37), (31, 38), (32, 38), (30, 39), (33, 39)] { set(x, y, steel[0]) }
for x in 26...37 {
    for y in 42...45 { set(x, y, x % 2 == 0 ? outline : steel[3]) }
}
for x in 26...37 { set(x, 41, steel[0]); set(x, 46, steel[0]) }

// Wraparound shades: frame from ear to ear, two lenses showing lines of a script.
for x in 17...46 {
    for y in 27...33 { set(x, y, frame) }
    set(x, 27, frameHi)
}
let lenses = [(19...30), (33...44)]
for lens in lenses {
    for x in lens {
        for y in 28...32 { set(x, y, lensDark) }
    }
}
// Script lines broken into words: bright on the left lens, a dimmer echo on the right.
let words: [(y: Int, left: [ClosedRange<Int>], right: [ClosedRange<Int>])] = [
    (29, [20...23, 25...29], [34...36, 38...43]),
    (31, [20...21, 23...27], [34...38, 40...41]),
]
for line in words {
    for word in line.left { for x in word { set(x, line.y, lensLine) } }
    for word in line.right { for x in word { set(x, line.y, lensDim) } }
}
set(20, 28, glare); set(34, 28, glare)

// One-pixel outline around the robot and its shades.
let shape = (0..<n * n).map { i -> Bool in
    let x = i % n, y = i / n
    return head[i] || jacket[i] || (x >= 17 && x <= 46 && y >= 27 && y <= 33)
}
for y in 0..<n {
    for x in 0..<n where !shape[y * n + x] {
        let touches = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { d in
            let nx = x + d.0, ny = y + d.1
            return nx >= 0 && ny >= 0 && nx < n && ny < n && shape[ny * n + nx]
        }
        if touches && inBody(x, y) { set(x, y, outline) }
    }
}
// The neck runs off the bottom edge; keep it inside the rounded square.
for y in 0..<n { for x in 0..<n where !inBody(x, y) { grid[y * n + x] = nil } }

// MARK: Render

func render(_ px: Int) -> Data {
    // Draw at 1024 with hard pixel edges, then let smaller sizes downsample smoothly.
    let big = 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: big, pixelsHigh: big, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let cell = big / n
    let data = rep.bitmapData!
    for py in 0..<big {
        for px2 in 0..<big {
            let o = (py * rep.bytesPerRow) + px2 * 4
            if let c = grid[(py / cell) * n + px2 / cell] {
                data[o] = c.r; data[o + 1] = c.g; data[o + 2] = c.b; data[o + 3] = 255
            } else {
                data[o] = 0; data[o + 1] = 0; data[o + 2] = 0; data[o + 3] = 0
            }
        }
    }
    guard px != big else { return rep.representation(using: .png, properties: [:])! }
    let small = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
    // Sizes that divide the grid evenly stay crisp; the rest blend.
    NSGraphicsContext.current?.imageInterpolation = px >= n && px % n == 0 ? .none : .high
    let image = NSImage(size: NSSize(width: big, height: big))
    image.addRepresentation(rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return small.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
