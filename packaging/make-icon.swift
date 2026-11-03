// Renders Quoder's app icon (a white Q on a teal rounded square) to PNG.
import AppKit
let size = Int(CommandLine.arguments[2])!
let s = CGFloat(size)
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let inset = s * 0.1
let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.56, blue: 0.51, alpha: 1),
           ending: NSColor(calibratedRed: 0.11, green: 0.36, blue: 0.33, alpha: 1))!.draw(in: path, angle: -90)
let font = NSFont.systemFont(ofSize: s * 0.52, weight: .bold)
let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded)!, size: s * 0.52) ?? font
let q = NSAttributedString(string: "Q", attributes: [.font: rounded, .foregroundColor: NSColor.white])
let qs = q.size()
q.draw(at: NSPoint(x: (s - qs.width) / 2, y: (s - qs.height) / 2 + s * 0.01))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
