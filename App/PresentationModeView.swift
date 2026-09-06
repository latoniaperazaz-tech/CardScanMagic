import Foundation
import Foundation
import SwiftUI

/// A self-contained calculator surface for live performances.
///
/// The view is deliberately only a visual overlay. It does not own, pause, or
/// inspect the camera session, so the recognition pipeline continues receiving
/// frames while the audience sees an ordinary calculator-style interface.
struct PresentationModeView: View {
    let isScanning: Bool
    let onExit: () -> Void

    @State private var calculator = CalculatorState()

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 16
            let keyGap: CGFloat = 10
            let keyWidth = max(
                54,
                (proxy.size.width - horizontalPadding * 2 - keyGap * 3) / 4
            )

            ZStack {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    header(safeTop: proxy.safeAreaInsets.top)

                    Spacer(minLength: 18)

                    display
                        .padding(.horizontal, horizontalPadding)

                    Spacer(minLength: 22)

                    keypad(keyWidth: keyWidth, gap: keyGap)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 10))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("计算器")
        .accessibilityHint("识别仍在后台运行")
    }

    private func header(safeTop: CGFloat) -> some View {
        HStack {
            // The low-contrast entry keeps the performance surface visually
            // clean while preserving a normal 44pt target and VoiceOver label.
            Button(action: onExit) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回识别设置")
            .accessibilityHint("退出计算器表演模式，返回识别界面")

            Spacer(minLength: 0)

            // A quiet title gives the screen a coherent app surface without
            // imitating a system status bar or another app's branding.
            Text("计算器")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.22))

            Spacer(minLength: 0)

            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, max(safeTop, 8))
    }

    private var display: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(calculator.expressionText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(calculator.display)
                .font(.system(size: 70, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.32)
                .allowsTightening(false)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("当前结果 (calculator.display)")
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .bottomTrailing)
        .accessibilityElement(children: .combine)
    }

    private func keypad(keyWidth: CGFloat, gap: CGFloat) -> some View {
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                key(.clear, width: keyWidth)
                key(.sign, width: keyWidth)
                key(.percent, width: keyWidth)
                key(.operation(.divide), width: keyWidth)
            }

            HStack(spacing: gap) {
                key(.digit("7"), width: keyWidth)
                key(.digit("8"), width: keyWidth)
                key(.digit("9"), width: keyWidth)
                key(.operation(.multiply), width: keyWidth)
            }

            HStack(spacing: gap) {
                key(.digit("4"), width: keyWidth)
                key(.digit("5"), width: keyWidth)
                key(.digit("6"), width: keyWidth)
                key(.operation(.subtract), width: keyWidth)
            }

            HStack(spacing: gap) {
                key(.digit("1"), width: keyWidth)
                key(.digit("2"), width: keyWidth)
                key(.digit("3"), width: keyWidth)
                key(.operation(.add), width: keyWidth)
            }

            HStack(spacing: gap) {
                key(.digit("0"), width: keyWidth * 2 + gap)
                key(.decimal, width: keyWidth)
                key(.equals, width: keyWidth)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func key(_ key: CalculatorKey, width: CGFloat) -> some View {
        Button {
            calculator.handle(key)
        } label: {
            Text(key.title)
                .font(.system(size: key == .digit("0") ? 31 : 27, weight: .medium, design: .rounded))
                .foregroundStyle(key.foregroundColor)
                .frame(width: width, height: width)
                .background(key.backgroundColor, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(CalculatorKeyButtonStyle())
        .accessibilityLabel(key.accessibilityTitle)
    }
}

private struct CalculatorKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private enum CalculatorOperation: Equatable {
    case add
    case subtract
    case multiply
    case divide

    var symbol: String {
        switch self {
        case .add: return "+"
        case .subtract: return "−"
        case .multiply: return "×"
        case .divide: return "÷"
        }
    }
}

private enum CalculatorKey: Equatable {
    case clear
    case sign
    case percent
    case operation(CalculatorOperation)
    case digit(String)
    case decimal
    case equals

    var title: String {
        switch self {
        case .clear: return "AC"
        case .sign: return "±"
        case .percent: return "%"
        case .operation(let operation): return operation.symbol
        case .digit(let digit): return digit
        case .decimal: return "."
        case .equals: return "="
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .clear: return "全部清除"
        case .sign: return "正负号"
        case .percent: return "百分号"
        case .operation(let operation):
            switch operation {
            case .add: return "加法"
            case .subtract: return "减法"
            case .multiply: return "乘法"
            case .divide: return "除法"
            }
        case .digit(let digit): return digit
        case .decimal: return "小数点"
        case .equals: return "等于"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .clear, .sign, .percent:
            return Color(red: 0.64, green: 0.65, blue: 0.67)
        case .operation, .equals:
            return Color(red: 0.96, green: 0.57, blue: 0.08)
        case .digit, .decimal:
            return Color(red: 0.20, green: 0.20, blue: 0.21)
        }
    }

    var foregroundColor: Color {
        switch self {
        case .clear, .sign, .percent:
            return .black
        default:
            return .white
        }
    }
}

/// State and behavior are kept local to presentation mode. No calculator
/// value can leak into card records or alter a scanning session.
private struct CalculatorState {
    private(set) var display = "0"
    private(set) var expressionText = ""

    private var storedValue: Double?
    private var pendingOperation: CalculatorOperation?
    private var waitingForOperand = false
    private var justEvaluated = false
    private var hasError = false

    mutating func handle(_ key: CalculatorKey) {
        switch key {
        case .digit(let digit):
            input(digit)
        case .decimal:
            inputDecimal()
        case .clear:
            reset()
        case .sign:
            toggleSign()
        case .percent:
            percentage()
        case .operation(let operation):
            setOperation(operation)
        case .equals:
            evaluate()
        }
    }

    private mutating func input(_ digit: String) {
        guard digit.count == 1 else { return }
        if hasError || justEvaluated {
            reset()
        }
        if waitingForOperand {
            display = digit
            waitingForOperand = false
        } else if display == "0" {
            display = digit
        } else if display.count < 15 {
            display.append(digit)
        }
    }

    private mutating func inputDecimal() {
        if hasError || justEvaluated {
            reset()
        }
        if waitingForOperand {
            display = "0."
            waitingForOperand = false
        } else if !display.contains(".") && display.count < 14 {
            display.append(".")
        }
    }

    private mutating func reset() {
        display = "0"
        expressionText = ""
        storedValue = nil
        pendingOperation = nil
        waitingForOperand = false
        justEvaluated = false
        hasError = false
    }

    private mutating func toggleSign() {
        guard !hasError, display != "0", display != "0." else { return }
        if display.first == "-" {
            display.removeFirst()
        } else {
            display.insert("-", at: display.startIndex)
        }
    }

    private mutating func percentage() {
        guard !hasError, let value = Double(display) else { return }
        display = format(value / 100)
    }

    private mutating func setOperation(_ operation: CalculatorOperation) {
        guard let value = Double(display), !hasError else { return }

        if let storedValue, let pendingOperation, !waitingForOperand {
            guard let result = apply(pendingOperation, lhs: storedValue, rhs: value) else {
                showError()
                return
            }
            self.storedValue = result
            display = format(result)
        } else if self.storedValue == nil || justEvaluated {
            storedValue = value
        }

        pendingOperation = operation
        waitingForOperand = true
        justEvaluated = false
        expressionText = "\(format(storedValue ?? value)) \(operation.symbol)"
    }

    private mutating func evaluate() {
        guard let operation = pendingOperation,
              let lhs = storedValue,
              let rhs = Double(display),
              !waitingForOperand,
              !hasError else {
            return
        }

        guard let result = apply(operation, lhs: lhs, rhs: rhs) else {
            showError()
            return
        }

        display = format(result)
        expressionText = "\(format(lhs)) \(operation.symbol) \(format(rhs)) ="
        storedValue = nil
        pendingOperation = nil
        waitingForOperand = false
        justEvaluated = true
    }

    private func apply(
        _ operation: CalculatorOperation,
        lhs: Double,
        rhs: Double
    ) -> Double? {
        let result: Double
        switch operation {
        case .add: result = lhs + rhs
        case .subtract: result = lhs - rhs
        case .multiply: result = lhs * rhs
        case .divide:
            guard abs(rhs) > .ulpOfOne else { return nil }
            result = lhs / rhs
        }
        guard result.isFinite else { return nil }
        return result
    }

    private mutating func showError() {
        display = "错误"
        expressionText = ""
        storedValue = nil
        pendingOperation = nil
        waitingForOperand = false
        justEvaluated = false
        hasError = true
    }

    private func format(_ value: Double) -> String {
        guard value.isFinite else { return "错误" }
        if value == 0 { return "0" }

        let absolute = abs(value)
        if absolute >= 1e10 || absolute < 1e-8 {
            return String(format: "%.6g", value)
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

#Preview {
    PresentationModeView(isScanning: true, onExit: {})
}
