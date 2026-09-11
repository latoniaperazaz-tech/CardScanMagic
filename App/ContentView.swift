import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()
    @State private var isRecordsExpanded = false
    @State private var isPresentationMode = true
    @State private var hasOpenedScanner = false
    @State private var clearFeedbackID = 0
    @State private var isShowingClearConfirmation = false

    var body: some View {
        GeometryReader { proxy in
            let drawerIsExpanded = isRecordsExpanded || (!viewModel.isScanning && !viewModel.isPreparing)
            let safeBottom = max(proxy.safeAreaInsets.bottom, 16)

            ZStack(alignment: .bottom) {
                CameraPreview(
                    session: viewModel.camera.session,
                    detections: viewModel.detections
                )
                // UIViewRepresentable has no useful intrinsic size. Give the
                // preview the actual screen dimensions so it cannot collapse
                // to a camera-sized strip on an iPhone 14 Pro.
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .ignoresSafeArea()
                // The preview is a display-only surface.  A UIKit view that
                // fills the screen can otherwise win hit testing in a ZStack
                // on some iOS releases, making the controls above it appear
                // tappable while silently swallowing the touch.
                .allowsHitTesting(false)
                .zIndex(-1)

                VStack(spacing: 10) {
                    topBar

                    // Keep the calculator entry below the Dynamic Island and
                    // outside the compact status capsule. The entire button
                    // has a stable 44pt hit area on iPhone 14 Pro.
                    calculatorEntry

                    Spacer(minLength: 0)

                    recordsDrawer(
                        isExpanded: drawerIsExpanded,
                        availableHeight: proxy.size.height,
                        safeBottom: safeBottom
                    )
                }
                .padding(.top, proxy.safeAreaInsets.top + 8)
                .ignoresSafeArea(edges: .bottom)
                // Keep the SwiftUI controls above the camera view and make
                // that ordering explicit for UIKit-backed previews.
                .zIndex(20)
                // Presentation mode is a visual-only cover. Keep the real
                // scanner out of the VoiceOver rotor as well, otherwise its
                // status and card records could be spoken while the cover is
                // active.
                .accessibilityHidden(isPresentationMode)

                if isPresentationMode {
                    PresentationModeView(
                        isScanning: viewModel.isScanning,
                        onExit: exitPresentationMode
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    // Cover the camera immediately. Fading the overlay in
                    // would briefly reveal the scanner and its card labels to
                    // anyone watching the phone during the switch.
                    .transition(.identity)
                    // The calculator must cover the scanner controls as well
                    // as the camera preview while presentation mode is on.
                    .zIndex(30)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.black)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // A short, native confirmation makes it immediately clear that the
        // reset control received the tap, even when there were no cards in
        // the history to visibly remove.
        .sensoryFeedback(.success, trigger: clearFeedbackID)
        .onChange(of: viewModel.isScanning) { _, isScanning in
            withAnimation(.easeInOut(duration: 0.22)) {
                // A stopped scanner is a review state; show the deal order when
                // the user turns the phone back over.
                isRecordsExpanded = !isScanning
            }
        }
        .alert(
            "扫描提示",
            isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { if !$0 { viewModel.alertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            topControl(
                systemImage: isShowingClearConfirmation ? "checkmark" : "trash",
                tint: isShowingClearConfirmation ? .green : .black,
                foreground: .white,
                accessibilityLabel: "清空本次记录",
                action: { clearCurrentRound() }
            )
            // A performance reset needs to happen on the first tap. An
            // action-sheet confirmation was easy to miss over the live
            // preview and made this control appear unresponsive on device.
            .accessibilityHint("点按立即清空本手记录并重置识别状态")
            // Leave a little more clearance below the Dynamic Island for the
            // reset control without creating a visual and hit-test position
            // mismatch. Padding participates in layout; offset does not.
            .padding(.top, 10)

            statusReadout

            cameraMenu

            topControl(
                systemImage: viewModel.isPreparing
                    ? "hourglass"
                    : (viewModel.isScanning
                        ? "pause.fill"
                        : (viewModel.isRoundComplete ? "checkmark.circle.fill" : "play.fill")),
                tint: viewModel.isPreparing
                    ? Color.gray
                    : (viewModel.isScanning
                        ? Color.orange
                        : (viewModel.isRoundComplete ? Color.blue : Color.green)),
                foreground: .black,
                accessibilityLabel: viewModel.isPreparing
                    ? "正在准备识别"
                    : (viewModel.isScanning
                        ? "暂停扫描"
                        : (viewModel.isRoundComplete
                            ? "本轮已完成，请先清空记录"
                            : "继续扫描")),
                action: {
                    viewModel.isScanning ? viewModel.stopScanning() : viewModel.startScanning()
                }
            )
            .disabled(viewModel.isPreparing || viewModel.isRoundComplete)
            .opacity(viewModel.isPreparing || viewModel.isRoundComplete ? 0.58 : 1)
            // Match the reset control's clearance below the Dynamic Island.
            .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
        // Give the whole bar a deterministic hit-test region.  This is
        // especially important when it sits over a full-screen
        // UIViewRepresentable and when the status-bar area is ignored.
        .contentShape(Rectangle())
        .zIndex(21)
        .allowsHitTesting(true)
    }

    private var cameraMenu: some View {
        Menu {
            ForEach(CameraSelection.allCases) { selection in
                Button {
                    viewModel.setCameraSelection(selection)
                } label: {
                    Label(selection.displayName, systemImage: selection == viewModel.cameraSelection ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "camera.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.92), in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.2), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .frame(width: 56, height: 56)
        .contentShape(Rectangle())
        .disabled(viewModel.isPreparing || viewModel.isScanning)
        .opacity(viewModel.isPreparing || viewModel.isScanning ? 0.48 : 1)
        .accessibilityLabel("选择摄像头")
    }

    private var statusReadout: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("炸金花 · 连续识别")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.74))

                Text(viewModel.statusText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.black.opacity(0.72), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("炸金花三张牌，\(viewModel.statusText)")
    }

    private var calculatorEntry: some View {
        Button(action: enterPresentationMode) {
            HStack(spacing: 8) {
                Image(systemName: "calculator.fill")
                    .font(.headline.weight(.semibold))

                Text("计算器")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 128, height: 44)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
        .accessibilityLabel("进入演示计算器")
        .accessibilityHint("点按打开计算器表演界面；识别会继续在后台运行")
    }

    private func enterPresentationMode() {
        guard !isPresentationMode else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isPresentationMode = true
        }
    }

    private func exitPresentationMode() {
        guard isPresentationMode else { return }
        if !hasOpenedScanner {
            hasOpenedScanner = true
            viewModel.startScanningIfNeeded()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            isPresentationMode = false
        }
    }

    private func clearCurrentRound() {
        viewModel.clearRecords()
        clearFeedbackID += 1
        withAnimation(.easeInOut(duration: 0.18)) {
            isRecordsExpanded = false
            isShowingClearConfirmation = true
        }

        let feedbackID = clearFeedbackID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard clearFeedbackID == feedbackID else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                isShowingClearConfirmation = false
            }
        }
    }

    private func topControl(
        systemImage: String,
        tint: Color,
        foreground: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(foreground)
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.92), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        // The 48pt circle stays visually compact, while the invisible
        // 56pt rectangular target is easier to hit during a performance.
        .frame(width: 56, height: 56)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    private func recordsDrawer(
        isExpanded: Bool,
        availableHeight: CGFloat,
        safeBottom: CGFloat
    ) -> some View {
        let compactContentHeight: CGFloat = 96
        // This reaches 460 pt on an iPhone 14 Pro: enough to review the deal
        // after turning the phone over, while retaining a visible camera area.
        let expandedContentHeight = min(460, max(280, availableHeight * 0.62))
        let contentHeight = isExpanded ? expandedContentHeight : compactContentHeight

        return VStack(spacing: 0) {
            if viewModel.isScanning {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isRecordsExpanded.toggle()
                    }
                } label: {
                    VStack(spacing: 0) {
                        drawerHandle
                        drawerSummary(isExpanded: isExpanded, isInteractable: true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起牌记录" : "展开牌记录")
                .accessibilityHint("双击可切换记录面板")
            } else {
                VStack(spacing: 0) {
                    drawerHandle
                    drawerSummary(isExpanded: true, isInteractable: false)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("扫描已暂停，正在显示本轮牌记录")
            }

            if isExpanded {
                Divider()
                    .overlay(.white.opacity(0.12))
                    .padding(.top, 4)

                RecordHistory(records: viewModel.records)
                    .padding(.top, 4)
            } else {
                Spacer(minLength: 0)
            }

            Color.clear
                .frame(height: safeBottom)
        }
        .frame(maxWidth: .infinity)
        .frame(height: contentHeight + safeBottom, alignment: .top)
        .background(.regularMaterial)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12,
                style: .continuous
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(height: 1)
        }
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
    }

    private var drawerHandle: some View {
        Capsule()
            .fill(.white.opacity(0.42))
            .frame(width: 34, height: 4)
            .padding(.top, 8)
            .padding(.bottom, 5)
            .accessibilityHidden(true)
    }

    private func drawerSummary(isExpanded: Bool, isInteractable: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本轮牌记录")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("\(viewModel.records.count) 张")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .contentTransition(.numericText())
            }
            .frame(width: 112, alignment: .leading)

            if let latestRecord = viewModel.records.last {
                LatestCardSummary(record: latestRecord)
            } else {
                Text("等待发牌")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            Image(systemName: isInteractable ? (isExpanded ? "chevron.down" : "chevron.up") : "list.bullet")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct LatestCardSummary: View {
    let record: CardRecord

    var body: some View {
        HStack(spacing: 8) {
            Text(record.card.displayText)
                .font(.title2.monospaced().weight(.bold))
                .foregroundStyle(record.card.displayColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text("最新")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text("\(Int(record.confidence * 100))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityLabel("最新识别 \(record.card.chineseName)，置信度 \(Int(record.confidence * 100))%")
    }
}

private struct RecordHistory: View {
    let records: [CardRecord]

    var body: some View {
        if records.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("尚未记录到牌")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            CardRecordRow(number: index + 1, record: record)
                                .id(record.id)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.visible)
                .onAppear {
                    scrollToLatest(with: proxy, animated: false)
                }
                .onChange(of: records.last?.id) { _, _ in
                    scrollToLatest(with: proxy, animated: true)
                }
            }
        }
    }

    private func scrollToLatest(with proxy: ScrollViewProxy, animated: Bool) {
        guard let latestID = records.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(latestID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(latestID, anchor: .bottom)
        }
    }
}

private struct CardRecordRow: View {
    let number: Int
    let record: CardRecord

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Text(record.card.displayText)
                .font(.title3.monospaced().weight(.bold))
                .foregroundStyle(record.card.displayColor)
                .frame(width: 58, alignment: .leading)

            Text(record.card.chineseName)
                .font(.body.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(Int(record.confidence * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(.white.opacity(0.12))
        }
        .accessibilityElement(children: .combine)
    }
}
