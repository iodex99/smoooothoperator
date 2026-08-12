import Foundation
import Testing
@testable import SOCore

@Suite("PiecewiseLinearCurve")
struct PiecewiseLinearCurveTests {
    private func makeCurve(_ points: [(Double, Double)]) -> PiecewiseLinearCurve? {
        PiecewiseLinearCurve(breakpoints: points.map { .init(x: $0.0, y: $0.1) })
    }

    @Test("clamps below the first breakpoint")
    func clampLow() throws {
        let curve = try #require(makeCurve([(0, 100), (10, 0)]))
        #expect(curve.value(at: -5) == 100)
    }

    @Test("clamps above the last breakpoint")
    func clampHigh() throws {
        let curve = try #require(makeCurve([(0, 100), (10, 0)]))
        #expect(curve.value(at: 25) == 0)
    }

    @Test("interpolates linearly between breakpoints")
    func interpolation() throws {
        let curve = try #require(makeCurve([(0, 100), (10, 0)]))
        #expect(curve.value(at: 5) == 50)
        #expect(curve.value(at: 2.5) == 75)
    }

    @Test("hits breakpoints exactly")
    func exactBreakpoints() throws {
        let curve = try #require(makeCurve([(0, 100), (4, 80), (10, 0)]))
        #expect(curve.value(at: 0) == 100)
        #expect(curve.value(at: 4) == 80)
        #expect(curve.value(at: 10) == 0)
    }

    @Test("multi-segment curve interpolates within the right segment")
    func multiSegment() throws {
        let curve = try #require(makeCurve([(0, 0), (10, 100), (20, 50)]))
        #expect(curve.value(at: 5) == 50)      // rising segment
        #expect(curve.value(at: 15) == 75)     // falling segment
    }

    @Test("single-breakpoint curve is a constant")
    func constant() throws {
        let curve = try #require(makeCurve([(3, 42)]))
        #expect(curve.value(at: -100) == 42)
        #expect(curve.value(at: 3) == 42)
        #expect(curve.value(at: 100) == 42)
    }

    @Test("rejects empty and non-increasing breakpoints")
    func invalidCurves() {
        #expect(makeCurve([]) == nil)
        #expect(makeCurve([(0, 1), (0, 2)]) == nil)   // duplicate x
        #expect(makeCurve([(5, 1), (3, 2)]) == nil)   // decreasing x
    }

    @Test("Codable round-trip")
    func codable() throws {
        let curve = try #require(makeCurve([(0, 100), (13.4, 85), (31.3, 40)]))
        let data = try JSONEncoder().encode(curve)
        let decoded = try JSONDecoder().decode(PiecewiseLinearCurve.self, from: data)
        #expect(decoded == curve)
    }
}
