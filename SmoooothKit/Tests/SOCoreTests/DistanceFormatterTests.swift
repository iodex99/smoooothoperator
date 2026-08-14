import Foundation
import Testing
@testable import SOCore

/// The bug this guards against shipped: the same 4.3 km course read as
/// "4.3 km" on Explore and "2.7 mi" on the course screen, because one was a
/// hard-coded string and the other went through a locale-aware formatter.
@Suite("Distance is never shown in one system")
struct DistanceFormatterTests {
    @Test("both systems always appear, in the reader's order")
    func bothSystems() {
        let meters = 4_300.0
        #expect(DistanceFormatter.both(meters: meters, primary: .metric) == "4.3 km · 2.7 mi")
        #expect(DistanceFormatter.both(meters: meters, primary: .imperial) == "2.7 mi · 4.3 km")
    }

    @Test("the two halves describe the same road")
    func agreement() {
        // A mile is a mile no matter which half you read.
        #expect(DistanceFormatter.metric(meters: DistanceFormatter.metersPerMile) == "1.6 km")
        #expect(DistanceFormatter.imperial(meters: DistanceFormatter.metersPerMile) == "1.0 mi")
        #expect(DistanceFormatter.metric(meters: 1_000) == "1.0 km")
        #expect(DistanceFormatter.imperial(meters: 1_000) == "0.6 mi")
    }

    @Test("short distances use the unit a person would actually say")
    func shortDistances() {
        // Nobody calls a 600 m road "0.6 km".
        #expect(DistanceFormatter.metric(meters: 600) == "600 m")
        #expect(DistanceFormatter.metric(meters: 999.6) == "1000 m")
        #expect(DistanceFormatter.metric(meters: 1_000) == "1.0 km")
        // Under a tenth of a mile, feet.
        #expect(DistanceFormatter.imperial(meters: 100) == "328 ft")
        #expect(DistanceFormatter.imperial(meters: 161) == "0.1 mi")
    }

    @Test("zero is a distance; nonsense is not")
    func edges() {
        #expect(DistanceFormatter.both(meters: 0) == "0 m · 0 ft")
        for bad in [Double.nan, .infinity, -.infinity, -1] {
            #expect(DistanceFormatter.both(meters: bad) == "—", "\(bad) must not render as a number")
            #expect(DistanceFormatter.metric(meters: bad) == "—")
            #expect(DistanceFormatter.imperial(meters: bad) == "—")
        }
    }

    @Test("the decimal separator never follows the device locale")
    func localeIndependent() {
        // A German device must not render "4,3 km" while the server and the
        // share card render "4.3 km" — the card is an image people compare.
        let text = DistanceFormatter.both(meters: 4_300)
        #expect(!text.contains(","))
        #expect(text.contains("4.3"))
    }

    @Test("rounding is half-away-from-zero and stable")
    func rounding() {
        #expect(DistanceFormatter.metric(meters: 4_250) == "4.3 km")
        #expect(DistanceFormatter.metric(meters: 4_249) == "4.2 km")
        // A long course still reads cleanly.
        #expect(DistanceFormatter.metric(meters: 42_195) == "42.2 km")
        #expect(DistanceFormatter.imperial(meters: 42_195) == "26.2 mi")
    }

    @Test("every real course length renders as two finite numbers", arguments: [
        1_000.0, 1_500, 2_700, 4_300, 8_000, 15_000, 50_000, 250_000,
    ])
    func realCourseLengths(meters: Double) {
        let text = DistanceFormatter.both(meters: meters)
        #expect(text.contains("km"))
        #expect(text.contains("mi"))
        #expect(!text.contains("nan"))
        #expect(!text.contains("inf"))
    }
}
