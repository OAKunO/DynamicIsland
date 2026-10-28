import SwiftUI
import AppKit

/// Preserve native keyboard editing while Text renders the numeric page transition.
struct AnimatedNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let title: String
    var digitSize: CGFloat
    var fieldWidth: CGFloat
    var fieldHeight: CGFloat
    var weight: Font.Weight
    var cornerRadius: CGFloat
    var backgroundOpacity: Double
    var focusColor: Color
    @State private var draftText: String
    @FocusState private var isValueFocused: Bool

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
         digitSize: CGFloat = 23, fieldWidth: CGFloat = 36, fieldHeight: CGFloat = 30,
         weight: Font.Weight = .medium, cornerRadius: CGFloat = 7,
         backgroundOpacity: Double = 0.10, focusColor: Color = .mint) {
        self.title = title
        _value = value
        self.range = range
        self.digitSize = digitSize
        self.fieldWidth = fieldWidth
        self.fieldHeight = fieldHeight
        self.weight = weight
        self.cornerRadius = cornerRadius
        self.backgroundOpacity = backgroundOpacity
        self.focusColor = focusColor
        _draftText = State(initialValue: String(value.wrappedValue))
    }

    private var displayedText: String { isValueFocused ? draftText : String(value) }
    private var textBinding: Binding<String> {
        Binding(get: { draftText }, set: { text in
            draftText = text
            guard let typedValue = Int(text) else { return }
            value = min(max(typedValue, range.lowerBound), range.upperBound)
        })
    }

    var body: some View {
        TextField(title, text: textBinding)
            .textFieldStyle(.plain)
            .focused($isValueFocused)
            .font(.system(size: digitSize, weight: weight, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(.clear)
            .tint(focusColor)
            .frame(width: fieldWidth, height: fieldHeight)
            .background(.white.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                Text(displayedText)
                    .font(.system(size: digitSize, weight: weight, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: fieldWidth, height: fieldHeight)
                    .contentTransition(.numericText(value: Double(displayedText) ?? Double(value)))
                    .animation(IslandMotion.control, value: displayedText)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isValueFocused ? focusColor.opacity(0.72) : .clear, lineWidth: 1)
            }
            .onChange(of: isValueFocused) { _, isFocused in
                draftText = String(value)
                if isFocused {
                    DispatchQueue.main.async {
                        guard let editor = WindowManager.window?.firstResponder as? NSTextView else { return }
                        editor.insertionPointColor = NSColor(focusColor)
                        editor.selectAll(nil)
                    }
                }
            }
            .onChange(of: value) { _, newValue in
                let clampedValue = min(max(newValue, range.lowerBound), range.upperBound)
                guard newValue == clampedValue else {
                    value = clampedValue
                    return
                }
                let draftValue = Int(draftText).map { min(max($0, range.lowerBound), range.upperBound) }
                if !isValueFocused || draftValue != newValue { draftText = String(newValue) }
            }
            .onSubmit { isValueFocused = false }
            .animation(IslandMotion.content, value: isValueFocused)
            .accessibilityLabel(title)
    }
}
