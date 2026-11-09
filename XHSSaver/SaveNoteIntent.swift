import AppIntents

/// 快捷指令里的「保存小红书笔记」操作：传入链接或整段分享文案即可
struct SaveNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "保存小红书笔记"
    static var description = IntentDescription("把小红书笔记里的原图、原视频和实况图存进相册。")
    /// 打开 App 在前台保存，避免大视频在后台下载时被系统中断
    static var openAppWhenRun: Bool = true

    @Parameter(title: "链接或分享文案")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("保存小红书笔记 \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = try await SaveService.shared.save(text: text)
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct XHSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveNoteIntent(),
            phrases: ["用\(.applicationName)保存小红书笔记"],
            shortTitle: "保存小红书笔记",
            systemImageName: "square.and.arrow.down"
        )
    }
}
