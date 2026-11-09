import SwiftUI

struct ContentView: View {
    @ObservedObject private var service = SaveService.shared
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘贴小红书链接或分享文案", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("input")
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            if let s = strings.first { text = s }
                        }
                        Spacer()
                        Button("清空") { text = "" }
                            .disabled(text.isEmpty)
                    }
                }

                Section {
                    Button {
                        let input = text
                        Task { _ = try? await service.save(text: input) }
                    } label: {
                        HStack {
                            Text(service.isRunning ? "正在保存…" : "保存到相册")
                            if service.isRunning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(service.isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save")
                }

                if !service.log.isEmpty {
                    Section("进度") {
                        ForEach(Array(service.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout)
                        }
                    }
                }

                Section {
                    Text("也可以在快捷指令里使用「保存小红书笔记」操作，配合分享菜单一键保存。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("小红书保存")
        }
    }
}
