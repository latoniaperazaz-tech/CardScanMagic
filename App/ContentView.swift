import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CameraPreview(session: viewModel.camera.session)
                    .frame(maxWidth: .infinity)
                    .frame(height: 250)
                    .overlay(alignment: .bottomLeading) {
                        Text(viewModel.statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(12)
                    }

                HStack(alignment: .firstTextBaseline) {
                    Text("识别记录")
                        .font(.headline)
                    Spacer()
                    Text("\(viewModel.records.count) 张")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if viewModel.records.isEmpty {
                    ContentUnavailableView(
                        "尚未识别到牌",
                        systemImage: "rectangle.on.rectangle"
                    )
                } else {
                    List {
                        ForEach(Array(viewModel.records.enumerated()), id: \.element.id) { index, record in
                            CardRecordRow(number: index + 1, record: record)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("发牌记录")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("清空记录")
                    .disabled(viewModel.records.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.isScanning ? viewModel.stopScanning() : viewModel.startScanning()
                    } label: {
                        Image(systemName: viewModel.isScanning ? "stop.fill" : "play.fill")
                    }
                    .accessibilityLabel(viewModel.isScanning ? "停止扫描" : "开始扫描")
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
    }
}

private struct CardRecordRow: View {
    let number: Int
    let record: CardRecord

    var body: some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Text(record.card.displayText)
                .font(.title3.weight(.bold))
                .foregroundStyle(record.card.displayColor)
                .frame(width: 62, alignment: .leading)

            Text(record.card.chineseName)
                .font(.body)

            Spacer()

            Text("\(Int(record.confidence * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
