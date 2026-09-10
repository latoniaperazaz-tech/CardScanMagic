import SwiftUI

struct RecognitionLiveTraceView: View {
    let text: String
    let updatedAt: Date
    let exportText: String
    let scanning: Bool
    @AppStorage("recognitionTraceEnabled") private var enabled = false
    @AppStorage("recognitionTraceLabel") private var label = "UNLABELLED"
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Toggle("Trace", isOn: $enabled).disabled(scanning)
                Button(expanded ? "收起" : "展开") { expanded.toggle() }
            }
            if expanded {
                Picker("测试", selection: $label) {
                    Text("未标记").tag("UNLABELLED")
                    Text("FULL 9C").tag("FULL 9C")
                    Text("OCCLUDED 9C").tag("OCCLUDED 9C")
                }
                .pickerStyle(.segmented).disabled(scanning)
                Text("开关/标签在下一轮开始生效；A/B 各自清空开始新轮").font(.caption2)
                if enabled {
                    ScrollView {
                        Text(text).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(maxHeight: 170)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("更新于 \(Int(max(0, context.date.timeIntervalSince(updatedAt)))) 秒前")
                            .font(.caption2)
                    }
                    if !exportText.isEmpty { Text(exportText).font(.caption2).lineLimit(2) }
                }
            }
        }
        .padding(8).background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white).padding(.horizontal, 16)
    }
}

