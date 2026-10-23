import FlowCore
import SwiftUI

/// Inspector row for one engine value: label with tooltip, unit-aware text field, optional slider.
///
/// `value` and `range` are always in engine (oilfield) units; conversion to the chosen display
/// system happens here.
struct ParameterRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var quantity: Quantity = .dimensionless
    var digits: Int = 2
    /// Slider moves in log10 space (useful for permeabilities spanning decades).
    var logarithmic: Bool = false
    var help: String = ""

    @Environment(\.unitSystem) private var units
    @AppStorage("showInspectorSliders") private var showSliders = true

    private var displayValue: Binding<Double> {
        Binding(
            get: { quantity.display(value, in: units) },
            set: { value = quantity.engine($0, from: units) }
        )
    }

    private var sliderValue: Binding<Double> {
        if logarithmic {
            return Binding(
                get: { log10(min(max(value, range.lowerBound), range.upperBound)) },
                set: { value = pow(10, $0) }
            )
        }
        return Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { value = $0 }
        )
    }

    private var sliderRange: ClosedRange<Double> {
        logarithmic ? log10(range.lowerBound)...log10(range.upperBound) : range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                TextField(title, value: displayValue, format: .number.precision(.fractionLength(quantity.digits(digits, in: units))))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                Text(quantity.symbol(units))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 46, alignment: .leading)
            }
            if showSliders {
                Slider(value: sliderValue, in: sliderRange)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
        .help(help.isEmpty ? title : help)
    }
}

/// A headline number with a caption, used across result panels.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var systemImage: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

/// Grid of stat tiles that wraps on narrow windows instead of squeezing.
struct StatGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
            content
        }
    }
}

/// A titled card that holds a chart or drawing.
struct ChartCard<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                accessory
            }
            content
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

extension ChartCard where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// Header shown at the top of each detail pane.
struct PaneHeader: View {
    let section: StudySection
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.title2.weight(.semibold))
                Text(section.subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Legend chip for a dashed reference curve.
struct ReferenceBadge: View {
    let label: String

    var body: some View {
        Label("Reference: \(label)", systemImage: "pin.fill")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.yellow.opacity(0.18), in: Capsule())
    }
}
