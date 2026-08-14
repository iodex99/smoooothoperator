import SOCore
import Foundation

/// Everything that names the product in one place.
///
/// The domain was spelled `smooooth.app` in ten separate string literals —
/// share text, the card footer, three legal links, the universal-links
/// entitlement — so moving to the real domain meant finding all ten. It
/// does not mean that again.
enum Brand {
    static let name = "Smooooth Operator"
    static let domain = "smoooothoperator.com"

    static var site: URL { URL(string: "https://\(domain)")! }
    static var terms: URL { URL(string: "https://\(domain)/terms")! }
    static var privacy: URL { URL(string: "https://\(domain)/privacy")! }
    static var support: URL { URL(string: "https://\(domain)/support")! }

    /// What a stranger reads on a shared card. Short enough to stay on one
    /// line at card scale.
    static let shortDomain = domain
}

extension DistanceFormatter.System {
    /// Which unit the reader sees first. Both are always shown — this only
    /// decides the order, so a US driver is not made to read kilometres
    /// first and a UK driver is not made to read miles first.
    static var deviceDefault: DistanceFormatter.System {
        if #available(iOS 16.0, *) {
            return Locale.current.measurementSystem == .metric ? .metric : .imperial
        }
        return .metric
    }
}

extension DistanceFormatter {
    /// Convenience for the UI: metres in, both units out, reader's first.
    static func label(meters: Double) -> String {
        both(meters: meters, primary: .deviceDefault)
    }
}
