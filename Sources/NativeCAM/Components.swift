import CAMCore
import SwiftUI

/// Numeric field that displays a millimetre value in the project's display units.
struct LengthField: View {
    let title: String
    @Binding var mm: Double
    let units: LengthUnit
    var help: String? = nil
    var minimum: Double? = nil

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(title, value: Binding(
                    get: { units.fromMM(mm) },
                    set: { v in
                        var m = units.toMM(v)
                        if let lo = minimum { m = max(lo, m) }
                        mm = m
                    }), format: .number.precision(.fractionLength(0...units.displayDecimals)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 70)
                Text(units.symbol).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            }
        } label: {
            Text(title)
        }
        .help(help ?? "")
    }
}

/// Feed rate in display units per minute (stored as mm/min).
struct FeedField: View {
    let title: String
    @Binding var mmPerMin: Double
    let units: LengthUnit

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding(get: { units.fromMM(mmPerMin) }, set: { mmPerMin = max(0.1, units.toMM($0)) }),
                          format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(minWidth: 70)
                Text(units == .inch ? "ipm" : "mm/m").foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            }
        }
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Double
    var suffix: String = ""
    var decimals: Int = 2
    var range: ClosedRange<Double>? = nil

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding(get: { value }, set: { v in
                    if let r = range { value = min(max(v, r.lowerBound), r.upperBound) } else { value = v }
                }), format: .number.precision(.fractionLength(0...decimals)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(minWidth: 70)
                if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary).frame(minWidth: 24, alignment: .leading) }
            }
        }
    }
}

struct IntField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...10_000

    var body: some View {
        LabeledContent(title) {
            Stepper(value: $value, in: range) {
                TextField(title, value: $value, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 60)
            }
        }
    }
}

/// Percent field backed by a 0–1 fraction.
struct PercentField: View {
    let title: String
    @Binding var fraction: Double

    var body: some View {
        NumberField(title: title, value: Binding(get: { fraction * 100 }, set: { fraction = max(1, min(100, $0)) / 100 }),
                    suffix: "%", decimals: 0)
    }
}

/// Technical side view of a tool: metallic body, helical flutes on the cutting length, and dimension lines
/// for diameter and cutting length (plus the included angle on tapered bits).
struct ToolShapeView: View {
    let tool: Tool
    var units: LengthUnit = .inch
    var showDimensions = true

    var body: some View {
        Canvas { ctx, size in
            let sil = tool.silhouette()
            guard let top = sil.map(\.y).max(), top > 0 else { return }
            let maxR = max(sil.map(\.x).max() ?? 1, 1e-3)
            // Room for dimension labels: right for cutting length, bottom for diameter.
            let rightPad: CGFloat = showDimensions ? 54 : 2
            let angled = tool.shape.usesAngle || tool.shape == .taperedBallNose || tool.shape == .dovetail
            let leftPad: CGFloat = showDimensions ? (angled ? 42 : 8) : 2
            let bottomPad: CGFloat = showDimensions ? 24 : 2
            let topPad: CGFloat = showDimensions ? 6 : 2
            let availW = size.width - leftPad - rightPad, availH = size.height - topPad - bottomPad
            let scale = max(0.01, min(availW / CGFloat(maxR * 2), availH / CGFloat(top)))
            let cx = leftPad + availW / 2
            let base = size.height - bottomPad - (availH - CGFloat(top) * scale) / 2
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: cx + CGFloat(x) * scale, y: base - CGFloat(y) * scale) }

            var outline = Path()
            outline.move(to: pt(sil[0].x, sil[0].y))
            for v in sil.dropFirst() { outline.addLine(to: pt(v.x, v.y)) }
            for v in sil.reversed() { outline.addLine(to: pt(-v.x, v.y)) }
            outline.closeSubpath()

            let left = cx - CGFloat(maxR) * scale, right = cx + CGFloat(maxR) * scale
            ctx.fill(outline, with: .linearGradient(
                Gradient(stops: [.init(color: Color(white: 0.48), location: 0), .init(color: Color(white: 0.93), location: 0.38),
                                 .init(color: Color(white: 0.70), location: 0.7), .init(color: Color(white: 0.42), location: 1)]),
                startPoint: CGPoint(x: left, y: 0), endPoint: CGPoint(x: right, y: 0)))

            // Flutes: slanted helix lines across the cutting length (a single straight flute on V and engraving bits).
            let cutTop = base - CGFloat(tool.fluteLength) * scale
            ctx.drawLayer { layer in
                layer.clip(to: outline)
                layer.clip(to: Path(CGRect(x: 0, y: cutTop, width: size.width, height: base - cutTop + 1)))
                var flutes = Path()
                if tool.shape.isTapered || tool.shape == .drill || tool.shape.cutsEdgesOnly {
                    flutes.move(to: pt(0, 0))
                    flutes.addLine(to: pt(tool.radius * 0.35, tool.fluteLength))
                } else {
                    let pitch = max(5, CGFloat(tool.diameter) * scale * 0.9)
                    let slant = CGFloat(tool.diameter) * scale * 0.6
                    var y = base + slant
                    while y > cutTop - slant {
                        flutes.move(to: CGPoint(x: left, y: y))
                        flutes.addLine(to: CGPoint(x: right, y: y - slant))
                        y -= pitch
                    }
                }
                layer.stroke(flutes, with: .color(Color(white: 0.2).opacity(0.55)), lineWidth: max(1, scale * CGFloat(tool.diameter) * 0.06))
            }
            ctx.stroke(outline, with: .color(Color(white: 0.15).opacity(0.8)), lineWidth: 1)
            // Shank / cutting-edge boundary (at the width the edge has there: a dovetail's neck, a form bit's top).
            var edge = Path()
            let edgeR = tool.shape.requiredFormatVersion > 1 ? tool.radius(atHeight: tool.fluteLength) : tool.radius
            edge.move(to: CGPoint(x: cx - CGFloat(edgeR) * scale, y: cutTop))
            edge.addLine(to: CGPoint(x: cx + CGFloat(edgeR) * scale, y: cutTop))
            ctx.stroke(edge, with: .color(.orange.opacity(0.8)), lineWidth: 1)

            guard showDimensions else { return }
            let dimColor = Color.secondary
            let decimals = units == .inch ? 3 : 2
            func label(_ s: String) -> Text { Text(s).font(.system(size: 10).monospacedDigit()).foregroundStyle(dimColor) }
            func tick(_ p: inout Path, _ a: CGPoint, horizontal: Bool) {
                if horizontal { p.move(to: CGPoint(x: a.x, y: a.y - 3)); p.addLine(to: CGPoint(x: a.x, y: a.y + 3)) }
                else { p.move(to: CGPoint(x: a.x - 3, y: a.y)); p.addLine(to: CGPoint(x: a.x + 3, y: a.y)) }
            }
            // Diameter, below the tool.
            let dy = base + 8
            var dia = Path()
            let dl = CGPoint(x: cx - CGFloat(tool.radius) * scale, y: dy), dr = CGPoint(x: cx + CGFloat(tool.radius) * scale, y: dy)
            dia.move(to: dl); dia.addLine(to: dr)
            tick(&dia, dl, horizontal: true); tick(&dia, dr, horizontal: true)
            ctx.stroke(dia, with: .color(dimColor), lineWidth: 0.75)
            ctx.draw(label("⌀ \(units.format(tool.diameter, decimals: decimals))"), at: CGPoint(x: cx, y: dy + 9))
            // Cutting length, to the right.
            let fx = right + 8
            var fl = Path()
            let ft = CGPoint(x: fx, y: cutTop), fb = CGPoint(x: fx, y: base)
            fl.move(to: ft); fl.addLine(to: fb)
            tick(&fl, ft, horizontal: false); tick(&fl, fb, horizontal: false)
            ctx.stroke(fl, with: .color(dimColor), lineWidth: 0.75)
            ctx.draw(label(units.format(tool.fluteLength, decimals: decimals)), at: CGPoint(x: fx + 5, y: (cutTop + base) / 2), anchor: .leading)
            // Included angle, beside the tip.
            if tool.shape.usesAngle {
                let h = min(tool.taperHeight > 0 ? tool.taperHeight : tool.fluteLength, tool.fluteLength)
                ctx.draw(label("\(Int(tool.includedAngle.rounded()))°"),
                         at: CGPoint(x: cx - CGFloat(tool.radius(atHeight: h * 0.5)) * scale - 4, y: base - CGFloat(h * 0.5) * scale),
                         anchor: .trailing)
            }
            // A tapered ball nose's and a dovetail's angle per side, halfway up the flutes; a tapered ball's tip radius.
            if tool.shape == .taperedBallNose || tool.shape == .dovetail {
                let h = tool.fluteLength * 0.5
                let perSide = (tool.includedAngle / 2).formatted(.number.precision(.fractionLength(0...2)))
                ctx.draw(label("\(perSide)°/side"),
                         at: CGPoint(x: cx - CGFloat(tool.radius(atHeight: h)) * scale - 4, y: base - CGFloat(h) * scale), anchor: .trailing)
            }
            if tool.shape == .taperedBallNose {
                ctx.draw(label("R\(units.format(tool.tipDiameter / 2, decimals: decimals))"),
                         at: CGPoint(x: cx - CGFloat(tool.tipDiameter / 2) * scale - 4, y: base - 4), anchor: .trailing)
            }
        }
        .accessibilityLabel("\(tool.shape.label), \(units.format(tool.diameter)) \(units.symbol) diameter")
    }
}
