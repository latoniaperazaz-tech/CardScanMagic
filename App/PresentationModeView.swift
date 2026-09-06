import SwiftUI

/// A neutral, non-branded surface for live performances.
///
/// This view deliberately does not own (or stop) the camera session. It is
/// presented above the scanner, so the recognition pipeline keeps receiving
/// frames while the card history and detection overlays are out of sight.
/// It is intentionally a generic standby/clock screen rather than an
/// imitation of iOS or another app.
struct PresentationModeView: View {
    let isScanning: Bool
    let onExit: () -> Void

    @State private var pulse = false

    var body: some View {
        ZStack {
            // An opaque surface is important here: the camera preview remains
            // alive underneath, but no card result is visible to an audience.
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.07, blue: 0.10),
                    Color(red: 0.015, green: 0.02, blue: 0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isScanning ? Color.green : Color.gray)
                        .frame(width: 9, height: 9)
                        .scaleEffect(pulse && isScanning ? 1.18 : 0.88)
                        .opacity(pulse && isScanning ? 1 : 0.72)
                        .animation(
                            .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                            value: pulse
                        )

                    Text(isScanning ? "已连接" : "待机")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))

                    Spacer(minLength: 0)

                    Text("桌面计时")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.42))
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)

                Spacer(minLength: 0)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .abbreviated)).minute().second())
                        .font(.system(size: 52, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                        .minimumScaleFactor(0.72)
                        .accessibilityLabel("当前时间")
                }

                Text("保持屏幕朝上即可")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.top, 10)

                Spacer(minLength: 0)

                // Keep the hint deliberately quiet in the visual design, but
                // expose the same action through VoiceOver below.
                Text("长按屏幕返回")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.22))
                    .padding(.bottom, 14)
            }
        }
        .contentShape(Rectangle())
        // A local gesture gives the performer a reliable exit even when the
        // normal controls are covered. It does not affect the capture session.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 1.2, maximumDistance: 36)
                .onEnded { _ in onExit() }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("演示待机画面。识别仍在后台运行")
        .accessibilityHint("长按屏幕，或使用辅助功能操作退出演示模式")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(named: Text("退出演示模式")) {
            onExit()
        }
        .onAppear {
            pulse = true
        }
    }
}

#Preview {
    PresentationModeView(isScanning: true, onExit: {})
}
