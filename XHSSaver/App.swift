import SwiftUI

@main
struct XHSSaverApp: App {
    init() {
        // 后台继续下载的任务要在启动完成之前登记
        BackgroundRun.shared.registerAtLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
