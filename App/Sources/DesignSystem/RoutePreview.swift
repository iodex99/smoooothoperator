import SOCore
import SwiftUI

/// Renders a course polyline as a glowing heat trace — no map tiles, so it
/// works offline, in cards, on the drive screen and on the share card, and
/// looks identical everywhere. `progress` lights up the driven portion.
struct RoutePreview: View {
    let route: [GeoCoordinate]
    var progress: Double = 1.0
    var lineWidth: CGFloat = 3.5
    var showsGates = true

    var body: some View {
        GeometryReader { proxy in
            let points = Self.project(route, into: proxy.size)
            if points.count > 1 {
                let litCount = max(2, Int(Double(points.count) * min(max(progress, 0), 1)))
                let lit = Array(points.prefix(litCount))
                ZStack {
                    trace(points)
                        .stroke(Color.white.opacity(0.13), style: stroke)
                    trace(lit)
                        .stroke(SOTheme.heatStart.opacity(0.55), style: glowStroke)
                        .blur(radius: 6)
                    trace(lit)
                        .stroke(
                            LinearGradient(
                                colors: [SOTheme.heatStart, SOTheme.heatEnd],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: stroke
                        )
                    if showsGates, let start = points.first, let finish = points.last {
                        Circle()
                            .fill(SOTheme.verified)
                            .frame(width: lineWidth * 2.4, height: lineWidth * 2.4)
                            .position(start)
                        Circle()
                            .strokeBorder(.white, lineWidth: 2)
                            .frame(width: lineWidth * 2.8, height: lineWidth * 2.8)
                            .position(finish)
                    }
                }
            }
        }
    }

    private var stroke: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }

    private var glowStroke: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth * 2.6, lineCap: .round, lineJoin: .round)
    }

    private func trace(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    /// Equirectangular projection (cos-lat corrected), aspect-fit centered.
    /// Display-only math — scoring geometry stays in the Kit.
    static func project(_ route: [GeoCoordinate], into size: CGSize) -> [CGPoint] {
        guard route.count > 1, size.width > 8, size.height > 8 else { return [] }
        let cosLat = cos(route[0].latitude * .pi / 180)
        let xs = route.map { $0.longitude * cosLat }
        let ys = route.map { $0.latitude }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return [] }
        let spanX = max(maxX - minX, 1e-9)
        let spanY = max(maxY - minY, 1e-9)
        let inset = 10.0
        let width = Double(size.width) - inset * 2
        let height = Double(size.height) - inset * 2
        let scale = min(width / spanX, height / spanY)
        let offsetX = inset + (width - spanX * scale) / 2.0
        let offsetY = inset + (height - spanY * scale) / 2.0
        return zip(xs, ys).map { x, y in
            CGPoint(x: offsetX + (x - minX) * scale, y: offsetY + (maxY - y) * scale)
        }
    }
}
