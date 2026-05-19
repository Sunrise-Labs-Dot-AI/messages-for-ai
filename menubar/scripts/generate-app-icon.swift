#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let scriptsDir = scriptURL.deletingLastPathComponent()
let menubarDir = scriptsDir.deletingLastPathComponent()
let assetsDir = menubarDir.appendingPathComponent("Assets", isDirectory: true)
let iconsetDir = assetsDir.appendingPathComponent("MessagesForAI.iconset", isDirectory: true)
let icnsURL = assetsDir.appendingPathComponent("MessagesForAI.icns")

try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let canvas: CGFloat = 1024

enum Variant: String, CaseIterable {
  case connectorHub = "connector-hub"
  case linkedBubbles = "linked-bubbles"
  case messageGatewaySpark = "message-gateway-spark"
  case messageGatewayNodes = "message-gateway-nodes"
  case messageGatewayPrompt = "message-gateway-prompt"
  case messageGatewayOrbit = "message-gateway-orbit"
  case messageGatewayPromptSky = "message-gateway-prompt-sky"
  case messageGatewayPromptMint = "message-gateway-prompt-mint"
  case messageGatewayPromptSage = "message-gateway-prompt-sage"
  case messageGatewayPromptLinen = "message-gateway-prompt-linen"

  var title: String {
    switch self {
    case .connectorHub: "Connector Hub"
    case .linkedBubbles: "Linked Bubbles"
    case .messageGatewaySpark: "Gateway Spark"
    case .messageGatewayNodes: "Gateway Nodes"
    case .messageGatewayPrompt: "Gateway Prompt"
    case .messageGatewayOrbit: "Gateway Orbit"
    case .messageGatewayPromptSky: "Prompt Sky"
    case .messageGatewayPromptMint: "Prompt Mint"
    case .messageGatewayPromptSage: "Prompt Sage"
    case .messageGatewayPromptLinen: "Prompt Linen"
    }
  }
}

let defaultVariant = Variant.messageGatewayPromptSky

enum HubMark {
  case spark
  case nodes
  case prompt
  case orbit
}

struct GatewayPalette {
  let tileTop: UInt32
  let tileBottom: UInt32
  let hubFill: UInt32
  let hubStroke: UInt32
  let shadowAlpha: CGFloat
}

let defaultGatewayPalette = GatewayPalette(
  tileTop: 0xf7faf8,
  tileBottom: 0xeaf2f0,
  hubFill: 0xf6fffb,
  hubStroke: 0x0b1c1f,
  shadowAlpha: 0.24
)

let promptSkyPalette = GatewayPalette(
  tileTop: 0xf7fbff,
  tileBottom: 0xe8f5ff,
  hubFill: 0xdff3ff,
  hubStroke: 0x82b7cd,
  shadowAlpha: 0.20
)

let promptMintPalette = GatewayPalette(
  tileTop: 0xf8fbf7,
  tileBottom: 0xecf8ef,
  hubFill: 0xdff7ea,
  hubStroke: 0x83b99e,
  shadowAlpha: 0.20
)

let promptSagePalette = GatewayPalette(
  tileTop: 0xf8faf6,
  tileBottom: 0xebf0ea,
  hubFill: 0xe2ece4,
  hubStroke: 0x8da598,
  shadowAlpha: 0.18
)

let promptLinenPalette = GatewayPalette(
  tileTop: 0xfffdf8,
  tileBottom: 0xf3f0e6,
  hubFill: 0xe5f5ed,
  hubStroke: 0x9eb49f,
  shadowAlpha: 0.18
)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  let r = CGFloat((hex >> 16) & 0xff) / 255
  let g = CGFloat((hex >> 8) & 0xff) / 255
  let b = CGFloat(hex & 0xff) / 255
  return CGColor(red: r, green: g, blue: b, alpha: alpha)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func bubblePath(_ rect: CGRect, tailSide: CGFloat) -> CGPath {
  if tailSide == 0 {
    return bubbleBodyPath(rect)
  }

  let r = min(rect.height * 0.36, 116)
  let minX = rect.minX
  let maxX = rect.maxX
  let minY = rect.minY
  let maxY = rect.maxY

  let body = CGMutablePath()
  body.move(to: CGPoint(x: minX + r, y: minY))
  body.addLine(to: CGPoint(x: maxX - r, y: minY))
  body.addCurve(
    to: CGPoint(x: maxX, y: minY + r),
    control1: CGPoint(x: maxX - r * 0.42, y: minY),
    control2: CGPoint(x: maxX, y: minY + r * 0.42)
  )
  body.addLine(to: CGPoint(x: maxX, y: maxY - r))
  body.addCurve(
    to: CGPoint(x: maxX - r, y: maxY),
    control1: CGPoint(x: maxX, y: maxY - r * 0.42),
    control2: CGPoint(x: maxX - r * 0.42, y: maxY)
  )
  body.addLine(to: CGPoint(x: minX + r, y: maxY))
  body.addCurve(
    to: CGPoint(x: minX, y: maxY - r),
    control1: CGPoint(x: minX + r * 0.42, y: maxY),
    control2: CGPoint(x: minX, y: maxY - r * 0.42)
  )
  body.addLine(to: CGPoint(x: minX, y: minY + r))
  body.addCurve(
    to: CGPoint(x: minX + r, y: minY),
    control1: CGPoint(x: minX, y: minY + r * 0.42),
    control2: CGPoint(x: minX + r * 0.42, y: minY)
  )
  body.closeSubpath()

  let tail = CGMutablePath()
  let baseX = tailSide < 0 ? minX + rect.width * 0.28 : maxX - rect.width * 0.28
  let tipX = tailSide < 0 ? minX + rect.width * 0.10 : maxX - rect.width * 0.10
  tail.move(to: CGPoint(x: baseX, y: minY + rect.height * 0.11))
  tail.addCurve(
    to: CGPoint(x: tipX, y: minY - rect.height * 0.16),
    control1: CGPoint(x: baseX - 28 * tailSide, y: minY - rect.height * 0.04),
    control2: CGPoint(x: tipX + 22 * tailSide, y: minY - rect.height * 0.14)
  )
  tail.addCurve(
    to: CGPoint(x: baseX + 82 * tailSide, y: minY + rect.height * 0.15),
    control1: CGPoint(x: tipX + 54 * tailSide, y: minY - rect.height * 0.10),
    control2: CGPoint(x: baseX + 46 * tailSide, y: minY + rect.height * 0.03)
  )
  tail.closeSubpath()

  let path = CGMutablePath()
  path.addPath(body)
  path.addPath(tail)
  return path
}

func bubbleBodyPath(_ rect: CGRect) -> CGPath {
  rounded(rect, min(rect.height * 0.36, 116))
}

func bubbleTailPath(_ rect: CGRect, tailSide: CGFloat) -> CGPath {
  if tailSide == 0 {
    return CGMutablePath()
  }

  let minX = rect.minX
  let maxX = rect.maxX
  let minY = rect.minY

  let tail = CGMutablePath()
  let baseX = tailSide < 0 ? minX + rect.width * 0.28 : maxX - rect.width * 0.28
  let tipX = tailSide < 0 ? minX + rect.width * 0.10 : maxX - rect.width * 0.10
  tail.move(to: CGPoint(x: baseX, y: minY + rect.height * 0.11))
  tail.addCurve(
    to: CGPoint(x: tipX, y: minY - rect.height * 0.16),
    control1: CGPoint(x: baseX - 28 * tailSide, y: minY - rect.height * 0.04),
    control2: CGPoint(x: tipX + 22 * tailSide, y: minY - rect.height * 0.14)
  )
  tail.addCurve(
    to: CGPoint(x: baseX + 82 * tailSide, y: minY + rect.height * 0.15),
    control1: CGPoint(x: tipX + 54 * tailSide, y: minY - rect.height * 0.10),
    control2: CGPoint(x: baseX + 46 * tailSide, y: minY + rect.height * 0.03)
  )
  tail.closeSubpath()
  return tail
}

func drawBase(_ ctx: CGContext, light: Bool = false, palette: GatewayPalette? = nil) {
  ctx.setShouldAntialias(true)
  ctx.setAllowsAntialiasing(true)

  let tile = CGRect(x: 80, y: 64, width: 864, height: 864)
  ctx.saveGState()
  ctx.addPath(rounded(tile, 202))
  ctx.clip()

  let base = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: palette.map { [color($0.tileTop), color($0.tileBottom)] as CFArray }
      ?? (light
        ? [color(0xf7faf8), color(0xeaf2f0)] as CFArray
        : [color(0x081014), color(0x101a1f)] as CFArray),
    locations: [0, 1]
  )!
  ctx.drawLinearGradient(base, start: CGPoint(x: 512, y: 928), end: CGPoint(x: 512, y: 64), options: [])
  ctx.restoreGState()

  ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 48, color: color(0x000000, alpha: light ? 0.18 : 0.46))
  ctx.addPath(rounded(tile, 202))
  ctx.setStrokeColor(color(light ? 0x0b1c1f : 0xffffff, alpha: light ? 0.10 : 0.14))
  ctx.setLineWidth(2)
  ctx.strokePath()
  ctx.setShadow(offset: .zero, blur: 0)
}

func fillBubble(
  _ ctx: CGContext,
  rect: CGRect,
  tailSide: CGFloat,
  top: UInt32,
  bottom: UInt32,
  shadowAlpha: CGFloat = 0.28
) {
  let path = bubblePath(rect, tailSide: tailSide)
  let body = bubbleBodyPath(rect)
  let tail = bubbleTailPath(rect, tailSide: tailSide)
  let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(top), color(bottom)] as CFArray,
    locations: [0, 1]
  )!

  ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: color(0x000000, alpha: shadowAlpha))
  ctx.addPath(path)
  ctx.setFillColor(color(bottom))
  ctx.fillPath()
  ctx.setShadow(offset: .zero, blur: 0)

  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.16),
    options: []
  )
  ctx.restoreGState()

  if tailSide == 0 {
    ctx.addPath(body)
    ctx.setStrokeColor(color(0xffffff, alpha: 0.22))
    ctx.setLineWidth(5)
    ctx.strokePath()
  }

  if tailSide != 0 {
    ctx.saveGState()
    ctx.addPath(tail)
    ctx.clip()
    ctx.drawLinearGradient(
      gradient,
      start: CGPoint(x: rect.midX, y: rect.maxY),
      end: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.16),
      options: []
    )
    ctx.restoreGState()
  }
}

func drawTypingDots(_ ctx: CGContext, center: CGPoint, spacing: CGFloat = 58, size: CGFloat = 30) {
  ctx.setFillColor(color(0xffffff, alpha: 0.92))
  for i in 0..<3 {
    ctx.fillEllipse(in: CGRect(
      x: center.x - spacing + CGFloat(i) * spacing - size / 2,
      y: center.y - size / 2,
      width: size,
      height: size
    ))
  }
}

func sparkPath(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
  let path = CGMutablePath()
  for i in 0..<8 {
    let angle = CGFloat(i) * .pi / 4 - .pi / 2
    let radius = i.isMultiple(of: 2) ? outer : inner
    let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    i == 0 ? path.move(to: point) : path.addLine(to: point)
  }
  path.closeSubpath()
  return path
}

func drawHubMark(_ ctx: CGContext, rect: CGRect, mark: HubMark, dark: Bool = false) {
  let center = CGPoint(x: rect.midX, y: rect.midY)

  switch mark {
  case .spark:
    ctx.addPath(sparkPath(center: center, outer: rect.width * 0.18, inner: rect.width * 0.055))
    ctx.setFillColor(color(0x0b2525))
    ctx.fillPath()
    ctx.addPath(sparkPath(
      center: CGPoint(x: center.x + rect.width * 0.18, y: center.y + rect.width * 0.17),
      outer: rect.width * 0.075,
      inner: rect.width * 0.024
    ))
    ctx.setFillColor(color(0x12d98a))
    ctx.fillPath()
    ctx.addPath(sparkPath(
      center: CGPoint(x: center.x - rect.width * 0.19, y: center.y - rect.width * 0.15),
      outer: rect.width * 0.062,
      inner: rect.width * 0.020
    ))
    ctx.setFillColor(color(0x34b7f2))
    ctx.fillPath()

  case .nodes:
    let points = [
      CGPoint(x: center.x - rect.width * 0.20, y: center.y + rect.width * 0.12),
      CGPoint(x: center.x + rect.width * 0.02, y: center.y + rect.width * 0.22),
      CGPoint(x: center.x + rect.width * 0.22, y: center.y + rect.width * 0.06),
      CGPoint(x: center.x - rect.width * 0.04, y: center.y - rect.width * 0.04),
      CGPoint(x: center.x - rect.width * 0.18, y: center.y - rect.width * 0.22),
      CGPoint(x: center.x + rect.width * 0.18, y: center.y - rect.width * 0.20),
    ]
    let links = [(0, 1), (1, 2), (0, 3), (3, 2), (3, 4), (3, 5), (4, 5)]
    ctx.setStrokeColor(color(0x143031, alpha: 0.35))
    ctx.setLineWidth(rect.width * 0.030)
    ctx.setLineCap(.round)
    for (a, b) in links {
      ctx.move(to: points[a])
      ctx.addLine(to: points[b])
      ctx.strokePath()
    }
    for (index, point) in points.enumerated() {
      ctx.setFillColor(color(index == 3 ? 0x0b2525 : 0x12d98a))
      let size = rect.width * (index == 3 ? 0.080 : 0.066)
      ctx.fillEllipse(in: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
    }

  case .prompt:
    ctx.setStrokeColor(color(0x0b2525))
    ctx.setLineWidth(rect.width * 0.050)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: center.x - rect.width * 0.22, y: center.y + rect.width * 0.12))
    chevron.addLine(to: CGPoint(x: center.x - rect.width * 0.08, y: center.y))
    chevron.addLine(to: CGPoint(x: center.x - rect.width * 0.22, y: center.y - rect.width * 0.12))
    ctx.addPath(chevron)
    ctx.strokePath()
    ctx.setFillColor(color(0x12d98a))
    ctx.addPath(rounded(
      CGRect(x: center.x + rect.width * 0.02, y: center.y - rect.width * 0.13, width: rect.width * 0.24, height: rect.width * 0.055),
      rect.width * 0.027
    ))
    ctx.fillPath()

  case .orbit:
    ctx.setStrokeColor(color(0x0b2525, alpha: 0.86))
    ctx.setLineWidth(rect.width * 0.038)
    ctx.setLineCap(.round)
    ctx.addEllipse(in: CGRect(x: center.x - rect.width * 0.17, y: center.y - rect.width * 0.17, width: rect.width * 0.34, height: rect.width * 0.34))
    ctx.strokePath()
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: 0.76)
    ctx.addEllipse(in: CGRect(x: -rect.width * 0.25, y: -rect.width * 0.10, width: rect.width * 0.50, height: rect.width * 0.20))
    ctx.setStrokeColor(color(0x12d98a, alpha: 0.92))
    ctx.setLineWidth(rect.width * 0.030)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.setFillColor(color(0x12d98a))
    ctx.fillEllipse(in: CGRect(x: center.x + rect.width * 0.16, y: center.y + rect.width * 0.08, width: rect.width * 0.07, height: rect.width * 0.07))
    ctx.setFillColor(color(0x0b2525))
    ctx.fillEllipse(in: CGRect(x: center.x - rect.width * 0.055, y: center.y - rect.width * 0.055, width: rect.width * 0.11, height: rect.width * 0.11))
  }
}

func drawHub(
  _ ctx: CGContext,
  rect: CGRect,
  dark: Bool = false,
  mark: HubMark = .nodes,
  palette: GatewayPalette? = nil
) {
  ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0x000000, alpha: palette?.shadowAlpha ?? (dark ? 0.34 : 0.24)))
  ctx.addPath(rounded(rect, rect.width * 0.23))
  ctx.setFillColor(color(palette?.hubFill ?? (dark ? 0x0d181d : 0xf6fffb), alpha: 0.98))
  ctx.fillPath()
  ctx.setShadow(offset: .zero, blur: 0)

  ctx.addPath(rounded(rect.insetBy(dx: 3, dy: 3), rect.width * 0.23 - 3))
  ctx.setStrokeColor(color(palette?.hubStroke ?? (dark ? 0xffffff : 0x0b1c1f), alpha: dark ? 0.15 : 0.18))
  ctx.setLineWidth(5)
  ctx.strokePath()

  drawHubMark(ctx, rect: rect, mark: mark, dark: dark)
}

func drawConnector(_ ctx: CGContext, from: CGPoint, to: CGPoint, stroke: UInt32, width: CGFloat = 32) {
  ctx.setStrokeColor(color(0xffffff, alpha: 0.88))
  ctx.setLineWidth(width)
  ctx.setLineCap(.round)
  ctx.move(to: from)
  ctx.addLine(to: to)
  ctx.strokePath()

  ctx.setStrokeColor(color(stroke, alpha: 0.92))
  ctx.setLineWidth(width * 0.48)
  ctx.move(to: from)
  ctx.addLine(to: to)
  ctx.strokePath()
}

func drawConnectorHub(_ ctx: CGContext) {
  drawBase(ctx)

  let blue = CGRect(x: 166, y: 542, width: 374, height: 214)
  let green = CGRect(x: 166, y: 268, width: 374, height: 214)
  let hub = CGRect(x: 584, y: 336, width: 260, height: 352)

  drawConnector(ctx, from: CGPoint(x: blue.maxX - 16, y: blue.midY), to: CGPoint(x: hub.minX + 18, y: hub.midY + 78), stroke: 0x0a84ff)
  drawConnector(ctx, from: CGPoint(x: green.maxX - 16, y: green.midY), to: CGPoint(x: hub.minX + 18, y: hub.midY - 78), stroke: 0x00a884)

  fillBubble(ctx, rect: blue, tailSide: -1, top: 0x53d4ff, bottom: 0x0a84ff)
  fillBubble(ctx, rect: green, tailSide: -1, top: 0x25d366, bottom: 0x00a884)
  drawTypingDots(ctx, center: CGPoint(x: blue.midX + 22, y: blue.midY + 8), spacing: 48, size: 26)
  drawTypingDots(ctx, center: CGPoint(x: green.midX + 22, y: green.midY + 8), spacing: 48, size: 26)
  drawHub(ctx, rect: hub, dark: false)
}

func drawLinkedBubbles(_ ctx: CGContext) {
  drawBase(ctx)

  let blue = CGRect(x: 154, y: 506, width: 560, height: 260)
  let green = CGRect(x: 306, y: 258, width: 560, height: 300)

  fillBubble(ctx, rect: blue, tailSide: -1, top: 0x53d4ff, bottom: 0x0a84ff)
  fillBubble(ctx, rect: green, tailSide: 1, top: 0x25d366, bottom: 0x00a884)

  let hub = CGRect(x: 394, y: 384, width: 236, height: 236)
  ctx.setStrokeColor(color(0xffffff, alpha: 0.90))
  ctx.setLineWidth(30)
  ctx.setLineCap(.round)
  ctx.move(to: CGPoint(x: blue.midX + 78, y: blue.midY - 28))
  ctx.addCurve(
    to: CGPoint(x: green.midX - 70, y: green.midY + 30),
    control1: CGPoint(x: 424, y: 502),
    control2: CGPoint(x: 598, y: 520)
  )
  ctx.strokePath()

  ctx.setStrokeColor(color(0x12d98a, alpha: 0.96))
  ctx.setLineWidth(14)
  ctx.move(to: CGPoint(x: blue.midX + 78, y: blue.midY - 28))
  ctx.addCurve(
    to: CGPoint(x: green.midX - 70, y: green.midY + 30),
    control1: CGPoint(x: 424, y: 502),
    control2: CGPoint(x: 598, y: 520)
  )
  ctx.strokePath()

  drawHub(ctx, rect: hub, dark: false)
}

func drawMessageGateway(
  _ ctx: CGContext,
  mark: HubMark,
  palette: GatewayPalette = defaultGatewayPalette
) {
  drawBase(ctx, light: true, palette: palette)

  let hub = CGRect(x: 176, y: 318, width: 276, height: 388)
  let blue = CGRect(x: 500, y: 484, width: 366, height: 210)
  let green = CGRect(x: 500, y: 330, width: 366, height: 210)

  drawConnector(ctx, from: CGPoint(x: hub.maxX - 16, y: hub.midY + 70), to: CGPoint(x: blue.minX + 6, y: blue.midY), stroke: 0x0a84ff, width: 28)
  drawConnector(ctx, from: CGPoint(x: hub.maxX - 16, y: hub.midY - 70), to: CGPoint(x: green.minX + 6, y: green.midY), stroke: 0x00a884, width: 28)

  drawHub(ctx, rect: hub, dark: false, mark: mark, palette: palette)
  fillBubble(ctx, rect: green, tailSide: 1, top: 0x25d366, bottom: 0x00a884, shadowAlpha: 0.18)
  fillBubble(ctx, rect: blue, tailSide: 1, top: 0x53d4ff, bottom: 0x0a84ff, shadowAlpha: 0.18)
}

func drawIcon(_ variant: Variant, into ctx: CGContext) {
  switch variant {
  case .connectorHub: drawConnectorHub(ctx)
  case .linkedBubbles: drawLinkedBubbles(ctx)
  case .messageGatewaySpark: drawMessageGateway(ctx, mark: .spark)
  case .messageGatewayNodes: drawMessageGateway(ctx, mark: .nodes)
  case .messageGatewayPrompt: drawMessageGateway(ctx, mark: .prompt)
  case .messageGatewayOrbit: drawMessageGateway(ctx, mark: .orbit)
  case .messageGatewayPromptSky: drawMessageGateway(ctx, mark: .prompt, palette: promptSkyPalette)
  case .messageGatewayPromptMint: drawMessageGateway(ctx, mark: .prompt, palette: promptMintPalette)
  case .messageGatewayPromptSage: drawMessageGateway(ctx, mark: .prompt, palette: promptSagePalette)
  case .messageGatewayPromptLinen: drawMessageGateway(ctx, mark: .prompt, palette: promptLinenPalette)
  }
}

func pngData(size: Int, variant: Variant) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [.alphaFirst],
    bytesPerRow: 0,
    bitsPerPixel: 0
  )!

  let context = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.cgContext.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
  drawIcon(variant, into: context.cgContext)
  NSGraphicsContext.restoreGraphicsState()

  return rep.representation(using: .png, properties: [:])!
}

for item in try FileManager.default.contentsOfDirectory(at: assetsDir, includingPropertiesForKeys: nil) {
  let name = item.lastPathComponent
  if name.hasPrefix("MessagesForAI-") && name.hasSuffix(".png") {
    try FileManager.default.removeItem(at: item)
  }
}

let iconFiles: [(String, Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for variant in Variant.allCases {
  try pngData(size: 1024, variant: variant)
    .write(to: assetsDir.appendingPathComponent("MessagesForAI-\(variant.rawValue).png"))
  try pngData(size: 128, variant: variant)
    .write(to: assetsDir.appendingPathComponent("MessagesForAI-\(variant.rawValue)-128.png"))
}

try pngData(size: 1024, variant: defaultVariant)
  .write(to: assetsDir.appendingPathComponent("MessagesForAI-preview.png"))

for (name, size) in iconFiles {
  try pngData(size: size, variant: defaultVariant)
    .write(to: iconsetDir.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
  "--convert", "icns",
  "--output", icnsURL.path,
  iconsetDir.path,
]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
  throw NSError(
    domain: "MessagesForAIIcon",
    code: Int(process.terminationStatus),
    userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]
  )
}

print("wrote \(icnsURL.path)")
for variant in Variant.allCases {
  print("preview \(variant.title): \(assetsDir.appendingPathComponent("MessagesForAI-\(variant.rawValue).png").path)")
}
