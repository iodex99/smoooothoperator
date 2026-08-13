import MapKit
import SOCore
import SwiftUI

/// Locates a course fraction on the polyline — position + travel bearing —
/// for the drive follow-cam. Display-only math; scoring geometry stays in
/// the Kit.
struct RouteLocator {
    private let route: [GeoCoordinate]
    private let cumulative: [Double]
    let totalMeters: Double

    init(route: [GeoCoordinate]) {
        self.route = route
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(route.count)
        var total = 0.0
        for index in 1..<max(route.count, 1) {
            total += route[index - 1].distance(to: route[index])
            cumulative.append(total)
        }
        self.cumulative = cumulative
        self.totalMeters = total
    }

    /// Position and heading at a 0...1 course fraction.
    func locate(fraction: Double) -> (position: GeoCoordinate, heading: Double) {
        guard route.count > 1, totalMeters > 0 else {
            return (route.first ?? GeoCoordinate(latitude: 0, longitude: 0), 0)
        }
        let target = totalMeters * min(max(fraction, 0), 1)
        var index = cumulative.firstIndex { $0 >= target } ?? cumulative.count - 1
        index = max(index, 1)
        let segmentStart = route[index - 1]
        let segmentEnd = route[index]
        let segmentLength = max(segmentStart.distance(to: segmentEnd), 1e-9)
        let within = (target - cumulative[index - 1]) / segmentLength
        let position = GeoCoordinate(
            latitude: segmentStart.latitude
                + (segmentEnd.latitude - segmentStart.latitude) * within,
            longitude: segmentStart.longitude
                + (segmentEnd.longitude - segmentStart.longitude) * within
        )
        // Heading from a slightly wider window so hairpin vertices don't
        // whip the camera.
        let lookBack = route[max(index - 2, 0)]
        let lookAhead = route[min(index + 1, route.count - 1)]
        return (position, lookBack.bearing(to: lookAhead))
    }

    /// Splits the polyline at a fraction: (covered, remaining).
    func split(at fraction: Double) -> ([GeoCoordinate], [GeoCoordinate]) {
        guard route.count > 1 else { return (route, route) }
        let target = totalMeters * min(max(fraction, 0), 1)
        var index = cumulative.firstIndex { $0 >= target } ?? cumulative.count - 1
        index = max(index, 1)
        let (position, _) = locate(fraction: fraction)
        let covered = Array(route[0..<index]) + [position]
        let remaining = [position] + Array(route[index...])
        return (covered, remaining)
    }
}

/// The glanceable drive map (user directive 2026-08-13: drivers need the
/// next turns). Follow-cam behind the driver, route ahead bright, covered
/// route in heat. NEVER interactive — no gestures, no buttons (spec §17).
struct DriveMapView: View {
    let route: [GeoCoordinate]
    let progress: Double
    /// nil = pre-drive states: frame the whole course instead of following.
    var follow: Bool = true

    @State private var camera: MapCameraPosition = .automatic
    @State private var lastCameraProgress = -1.0

    private var locator: RouteLocator { RouteLocator(route: route) }

    var body: some View {
        Map(position: $camera, interactionModes: []) {
            let (covered, remaining) = locator.split(at: progress)
            MapPolyline(coordinates: remaining.map(coordinate))
                .stroke(
                    Color.white.opacity(0.85),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                )
            if covered.count > 1 {
                MapPolyline(coordinates: covered.map(coordinate))
                    .stroke(
                        SOTheme.heatStart,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                    )
            }
            if let start = route.first {
                Annotation("", coordinate: coordinate(start)) {
                    GateMarker(color: SOTheme.verified, icon: "flag.fill")
                }
            }
            if let finish = route.last {
                Annotation("", coordinate: coordinate(finish)) {
                    GateMarker(color: .white, icon: "flag.checkered")
                }
            }
            if follow {
                let (position, _) = locator.locate(fraction: progress)
                Annotation("", coordinate: coordinate(position)) {
                    DriverPuck()
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // No controls: the heading-rotated follow-cam would otherwise show
        // a compass over the drive overlay.
        .mapControls {}
        .allowsHitTesting(false)
        .onAppear { updateCamera(force: true) }
        .onChange(of: progress) { updateCamera(force: false) }
    }

    private func coordinate(_ geo: GeoCoordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude)
    }

    /// Re-aims the follow-cam every ~2% of course (≈ every 100 m on a 5 km
    /// course) so the camera glides instead of thrashing at sensor rate.
    private func updateCamera(force: Bool) {
        guard follow else {
            if force { camera = .automatic }
            return
        }
        guard force || abs(progress - lastCameraProgress) >= 0.02 else { return }
        lastCameraProgress = progress
        let (position, heading) = locator.locate(fraction: progress)
        withAnimation(.easeInOut(duration: 1.2)) {
            camera = .camera(MapCamera(
                centerCoordinate: coordinate(position),
                distance: 1400,
                heading: heading,
                pitch: 55
            ))
        }
    }
}

/// The driver's position. The follow-cam keeps the map heading-aligned, so
/// screen-up IS the direction of travel — the puck never rotates.
struct DriverPuck: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(SOTheme.heatStart.opacity(0.25))
                .frame(width: 44, height: 44)
            Image(systemName: "location.north.fill")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .padding(7)
                .background(SOTheme.heat, in: Circle())
                .shadow(color: SOTheme.heatStart.opacity(0.8), radius: 8)
        }
    }
}
