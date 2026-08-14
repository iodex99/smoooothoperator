import SwiftUI

/// About + attributions.
///
/// The course catalog is derived from OpenStreetMap data under the ODbL,
/// which obliges us to credit it in the app — not only in the repository.
/// docs/COURSES.md has said "the app's About screen must credit
/// OpenStreetMap" since the catalog was built; this is that screen.
struct AboutView: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(v ?? "1.0") (\(build ?? "1"))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Wordmark()
                    .padding(.top, 20)
                Text("Version \(version)")
                    .font(.footnote)
                    .foregroundStyle(SOTheme.textSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("COURSE DATA")
                        .font(.caption.weight(.black))
                        .tracking(1.4)
                        .foregroundStyle(SOTheme.heatStart)
                    Text("Road geometry is derived from OpenStreetMap.")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    Text("© OpenStreetMap contributors, available under the Open Database Licence (ODbL). Routing by OSRM. Course names and descriptions are our own.")
                        .font(.footnote)
                        .foregroundStyle(SOTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("openstreetmap.org/copyright",
                         destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.footnote.weight(.semibold))
                        .tint(SOTheme.heatStart)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .soCard(padding: 18)

                VStack(alignment: .leading, spacing: 10) {
                    Text("THE RULES")
                        .font(.caption.weight(.black))
                        .tracking(1.4)
                        .foregroundStyle(SOTheme.heatStart)
                    Text("Smooooth Operator scores how well you drive, not how fast. Speeding and aggression lower your score. Never interact with the app while driving.")
                        .font(.footnote)
                        .foregroundStyle(SOTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .soCard(padding: 18)

                HStack(spacing: 18) {
                    Link("Terms", destination: Brand.terms)
                    Link("Privacy", destination: Brand.privacy)
                    Link("Support", destination: Brand.support)
                }
                .font(.footnote.weight(.semibold))
                .tint(SOTheme.heatStart)
            }
            .padding(18)
        }
        .background(SOTheme.ground)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
