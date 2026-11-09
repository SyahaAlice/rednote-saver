import AppIntents

/// 快捷指令里的「下载到相册」操作：传入链接或整段分享文案即可
struct SaveNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "下载到相册"
    static var description = IntentDescription("把链接里的图片、视频和实况照片存进相册：小红书、抖音由 App 自己解析，其它网站用内置的 yt-dlp。")
    /// 打开 App 在前台保存，避免大视频在后台下载时被系统中断
    static var openAppWhenRun: Bool = true

    @Parameter(title: "链接或分享文案")
    var text: String

    /// 打开 = 快速保存（不预览、不选相册，全部保存）；关闭 = 和 App 里的「解析」一样先预览
    @Parameter(title: "快速保存", default: false)
    var quick: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("下载 \(\.$text) 到相册")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = try await SaveService.shared.save(text: text, mode: quick ? .quick : .organize)
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct XHSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveNoteIntent(),
            phrases: ["用\(.applicationName)下载到相册"],
            shortTitle: "下载到相册",
            systemImageName: "square.and.arrow.down"
        )
    }
}
