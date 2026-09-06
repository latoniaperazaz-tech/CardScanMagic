import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()
    @State private var showingClearConfirmation = false
    @State private var isRecordsExpanded = false

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

                VStack(spacing: 0) {
                    topBar
                        .padding(.top, proxy.safeAreaInsets.top + 8)

                    Spacer(minLength: 0)

                    recordsDrawer(
                        isExpanded: drawerIsExpanded,
                        availableHeight: proxy.size.height,
                        safeBottom: safeBottom
                    )
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.black)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .task {
            viewModel.startScanningIfNeeded()
        }
        .onChange(of: viewModel.isScanning) { _, isScanning in
            withAnimation(.easeInOut(duration: 0.22)) {
                // A stopped scanner is a review state; show the deal order when
                // the user turns the phone back over.
                isRecordsExpanded = !isScanning
            }
        }
        .confirmationDialog("清空本次记录？", isPresented: $showingClearConfirmation) {
            Button("清空", role: .destructive) {
                viewModel.clearRecords()
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
        HStack(spacing: 10) {
            topControl(
                systemImage: "trash",
                tint: .black,
                foreground: .white,
                accessibilityLabel: "清空本次记录",
                action: { showingClearConfirmation = true }
            )
            .disabled(viewModel.records.isEmpty)
            .opacity(viewModel.records.isEmpty ? 0.42 : 1)

            statusReadout

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
        }
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
    }

    private var statusReadout: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("炸金花 · 三张牌")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.74))

            Text(viewModel.statusText)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.black.opacity(0.72), in: Capsule())
        .accessibilityElement(children: .combine)
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
                .accessibilityLabel(isExpanded ? "收起三张牌记录" : "展开三张牌记录")
                .accessibilityHint("双击可切换记录面板")
            } else {
                VStack(spacing: 0) {
                    drawerHandle
                    drawerSummary(isExpanded: true, isInteractable: false)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("扫描已暂停，正在显示本手三张牌记录")
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
                Text("本手牌（最多三张）")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("\(viewModel.records.count)/\(ScanViewModel.cardsPerRound) 张")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .contentTransition(.numericText())
            }
            .frame(width: 112, alignment: .leading)

            if let latestRecord = viewModel.records.last {
                LatestCardSummary(record: latestRecord)
            } else {
                Text("等待发牌（最多三张）")
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
