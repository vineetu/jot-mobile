import SwiftUI

struct RecentsSparkline: View {
    let values: [TimeInterval]
    var width: CGFloat = 92
    var height: CGFloat = 36

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let points = Self.points(for: values, in: rect)
            let linePath = Self.smoothPath(points: points)
            let fillPath = Self.fillPath(points: points, in: rect)

            ZStack {
                fillPath
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.jotBlueTop.opacity(0.30),
                                Color.jotBlueTop.opacity(0.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                linePath
                    .stroke(
                        Color.jotBlueTop,
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                    )

                if let last = points.last {
                    Circle()
                        .fill(Color.jotBlueTop)
                        .frame(width: 6, height: 6)
                        .position(last)
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    private static func points(for values: [TimeInterval], in rect: CGRect) -> [CGPoint] {
        let samples = values.isEmpty ? [0] : values
        let maxValue = max(samples.max() ?? 0, 1)
        let topInset: CGFloat = 4
        let bottomInset: CGFloat = 4
        let leftInset: CGFloat = 2
        let rightInset: CGFloat = 4
        let drawableWidth = max(1, rect.width - leftInset - rightInset)
        let drawableHeight = max(1, rect.height - topInset - bottomInset)

        return samples.enumerated().map { index, value in
            let x: CGFloat
            if samples.count == 1 {
                x = rect.midX
            } else {
                x = leftInset + drawableWidth * CGFloat(index) / CGFloat(samples.count - 1)
            }
            let normalized = CGFloat(max(0, value) / maxValue)
            let y = topInset + (1 - normalized) * drawableHeight
            return CGPoint(x: x, y: y)
        }
    }

    private static func smoothPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 1 else { return path }
        for index in 0..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let previous = index > 0 ? points[index - 1] : current
            let following = index + 2 < points.count ? points[index + 2] : next
            let control1 = CGPoint(
                x: current.x + (next.x - previous.x) / 6,
                y: current.y + (next.y - previous.y) / 6
            )
            let control2 = CGPoint(
                x: next.x - (following.x - current.x) / 6,
                y: next.y - (following.y - current.y) / 6
            )
            path.addCurve(to: next, control1: control1, control2: control2)
        }
        return path
    }

    private static func fillPath(points: [CGPoint], in rect: CGRect) -> Path {
        var path = smoothPath(points: points)
        guard let first = points.first, let last = points.last else { return path }
        let baseline = rect.maxY - 1
        path.addLine(to: CGPoint(x: last.x, y: baseline))
        path.addLine(to: CGPoint(x: first.x, y: baseline))
        path.closeSubpath()
        return path
    }
}
