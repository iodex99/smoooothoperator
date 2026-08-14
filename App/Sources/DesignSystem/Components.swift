import SwiftUI

/// Circular progress ring with the heat gradient and a soft glow — the
/// signature score/rating visual.
struct GlowRing: View {
    var progress: Double // 0...1
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(SOTheme.elevated, lineWidth: lineWidth)
            ring
                .blur(radius: 10)
                .opacity(0.65)
            ring
        }
        .padding(lineWidth / 2)
    }

    private var ring: some View {
        Circle()
            .trim(from: 0, to: min(max(progress, 0.004), 1))
            .stroke(
                AngularGradient(
                    colors: [SOTheme.heatStart, SOTheme.heatEnd, SOTheme.heatStart],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
    }
}

/// Horizontal metric bar with the heat fill — sub-scores, battery-of-skill.
struct HeatBar: View {
    var progress: Double // 0...1
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SOTheme.elevated)
                Capsule()
                    .fill(SOTheme.heat)
                    .frame(width: max(height, proxy.size.width * min(max(progress, 0), 1)))
                    .shadow(color: SOTheme.heatStart.opacity(0.5), radius: 5)
            }
        }
        .frame(height: height)
    }
}

/// Small labeled metric tile.
struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(SOTheme.textSecondary)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SOTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(SOTheme.hairline, lineWidth: 1)
        )
    }
}

/// Compact icon+text capsule (distances, turns, drivers…).
struct SOChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(SOTheme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(SOTheme.elevated, in: Capsule())
    }
}

/// Filter chip row option — replaces stock segmented pickers.
struct SelectableChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(selected ? .black : SOTheme.textSecondary)
                .padding(.horizontal, 18)
                // 44pt. Every filter chip in Explore and Leaderboards is one
                // of these, and they were ~35pt — small enough to miss, and
                // there are four of them side by side.
                .frame(minHeight: 44)
                .background {
                    if selected {
                        Capsule().fill(SOTheme.heat)
                            .shadow(color: SOTheme.heatStart.opacity(0.4), radius: 8, y: 3)
                    } else {
                        Capsule().fill(SOTheme.surface)
                    }
                }
                .overlay {
                    if !selected {
                        Capsule().strokeBorder(SOTheme.hairline, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(SOTheme.textSecondary)
            Spacer()
        }
        .padding(.top, 6)
    }
}

struct EmptyHint: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(SOTheme.heatStart)
                .frame(width: 34, height: 34)
                .background(SOTheme.heatStart.opacity(0.12), in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(SOTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .soCard(padding: 14)
    }
}

/// The wordmark, used on Home and the share card.
struct Wordmark: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text("SMOOOOTH")
                .font(.system(size: compact ? 18 : 30, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("OPERATOR")
                .font(.system(size: compact ? 10 : 15, weight: .black, design: .rounded))
                .tracking(compact ? 3.4 : 6.4)
                .foregroundStyle(SOTheme.heat)
        }
    }
}
