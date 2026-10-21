import SwiftUI

/// A labelled numeric input: exact value in a text field, quick exploration with a slider.
struct ParameterRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    var digits: Int = 2
    /// Slider moves in log10 space (useful for permeabilities spanning decades).
    var logarithmic: Bool = false

    private var sliderValue: Binding<Double> {
        guard logarithmic else { return $value }
        return Binding(
            get: { log10(max(value, range.lowerBound)) },
            set: { value = pow(10, $0) }
        )
    }

    private var sliderRange: ClosedRange<Double> {
        logarithmic ? log10(range.lowerBound)...log10(range.upperBound) : range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 4)
                TextField(title, value: $value, format: .number.precision(.fractionLength(digits)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 84)
                Text(unit)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 54, alignment: .leading)
            }
            Slider(value: sliderValue, in: sliderRange)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// A headline number with a caption, used across result panels.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A titled card that holds a chart.
struct ChartCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension Double {
    func formatted(digits: Int) -> String {
        formatted(.number.precision(.fractionLength(digits)))
    }
}
