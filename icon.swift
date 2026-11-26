// Dibuja el icono de Eco (1024x1024) en el PNG que se pase como argumento.
import AppKit

let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Fondo: squircle con margen estándar de macOS (824 px dentro de 1024).
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor.black.setFill(); shape.fill()
ctx.restoreGState()
shape.addClip()
NSGradient(colors: [NSColor(red: 0.29, green: 0.20, blue: 0.85, alpha: 1),
                    NSColor(red: 0.10, green: 0.72, blue: 0.78, alpha: 1)])!
    .draw(in: rect, angle: -55)

// Ondas de sonido: barras redondeadas, simétricas.
NSColor.white.setFill()
let heights: [CGFloat] = [130, 260, 420, 300, 520, 300, 420, 260, 130]
let barW: CGFloat = 46, gap: CGFloat = 26
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (s - total) / 2
for h in heights {
    NSBezierPath(roundedRect: CGRect(x: x, y: s / 2 - h / 2 - 20, width: barW, height: h), xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}

// Destello de IA arriba a la derecha.
func sparkle(_ c: CGPoint, _ r: CGFloat) {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + r * 0.15, y: c.y + r * 0.15), controlPoint2: CGPoint(x: c.x + r * 0.15, y: c.y + r * 0.15))
    p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x + r * 0.15, y: c.y - r * 0.15), controlPoint2: CGPoint(x: c.x + r * 0.15, y: c.y - r * 0.15))
    p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - r * 0.15, y: c.y - r * 0.15), controlPoint2: CGPoint(x: c.x - r * 0.15, y: c.y - r * 0.15))
    p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x - r * 0.15, y: c.y + r * 0.15), controlPoint2: CGPoint(x: c.x - r * 0.15, y: c.y + r * 0.15))
    p.fill()
}
NSColor(red: 1, green: 0.88, blue: 0.45, alpha: 1).setFill()
sparkle(CGPoint(x: 760, y: 770), 80)
NSColor.white.withAlphaComponent(0.85).setFill()
sparkle(CGPoint(x: 660, y: 830), 36)
img.unlockFocus()

let rep = NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
