import AppKit

let destination = CommandLine.arguments[1]
let size = 1024
let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let ink = NSColor(calibratedWhite: 0.13, alpha: 1)
ink.setStroke()
let bubble = NSBezierPath()
bubble.move(to: NSPoint(x: 330, y: 790))
bubble.line(to: NSPoint(x: 694, y: 790))
bubble.curve(to: NSPoint(x: 820, y: 664), controlPoint1: NSPoint(x: 786, y: 790), controlPoint2: NSPoint(x: 820, y: 756))
bubble.line(to: NSPoint(x: 820, y: 464))
bubble.curve(to: NSPoint(x: 694, y: 338), controlPoint1: NSPoint(x: 820, y: 372), controlPoint2: NSPoint(x: 786, y: 338))
bubble.line(to: NSPoint(x: 500, y: 338))
bubble.line(to: NSPoint(x: 371, y: 217))
bubble.curve(to: NSPoint(x: 350, y: 226), controlPoint1: NSPoint(x: 360, y: 206), controlPoint2: NSPoint(x: 350, y: 212))
bubble.line(to: NSPoint(x: 350, y: 338))
bubble.line(to: NSPoint(x: 330, y: 338))
bubble.curve(to: NSPoint(x: 204, y: 464), controlPoint1: NSPoint(x: 238, y: 338), controlPoint2: NSPoint(x: 204, y: 372))
bubble.line(to: NSPoint(x: 204, y: 664))
bubble.curve(to: NSPoint(x: 330, y: 790), controlPoint1: NSPoint(x: 204, y: 756), controlPoint2: NSPoint(x: 238, y: 790))
bubble.close()
bubble.lineWidth = 42
bubble.lineJoinStyle = .round
bubble.stroke()
let prompt = NSBezierPath()
prompt.move(to: NSPoint(x: 371, y: 610))
prompt.line(to: NSPoint(x: 446, y: 556))
prompt.line(to: NSPoint(x: 371, y: 502))
prompt.lineWidth = 37
prompt.lineCapStyle = .round
prompt.lineJoinStyle = .round
prompt.stroke()
let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 508, y: 502))
cursor.line(to: NSPoint(x: 618, y: 502))
cursor.lineWidth = 37
cursor.lineCapStyle = .round
cursor.stroke()
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: canvas.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
