import BackgroundTasks
import UIKit

/// 保存期间让 App 不被系统打断，分三层：
/// 1. 不自动锁屏（放着等它下完，屏幕不会自己熄灭）。
/// 2. 切到别的 App 时向系统多要一点时间（约 30 秒，够把手头这一项存完）。
/// 3. iOS 26 起：申请「后台继续」的任务，切走或锁屏后接着下载，系统在灵动岛 / 锁屏上显示进度。
///    申请不到（系统版本低、系统不批准）时只有前两层。
@MainActor
final class BackgroundRun {
    static let shared = BackgroundRun()

    /// Info.plist 的 BGTaskSchedulerPermittedIdentifiers 里登记的任务名
    private static let fixedID = "com.personal.xhssaver.save"

    private var running = false
    private var short = UIBackgroundTaskIdentifier.invalid
    /// 启动时登记成功的任务名
    private var registered: [String] = []
    /// 已经提交、系统还没开始的任务名
    private var submitted: String?
    private var task: BGTask?
    private var ticker: Task<Void, Never>?
    private var done: Int64 = 0

    /// 侧载工具可能会改 Bundle ID（在后面加一段），所以两个名字都试：跟着当前 Bundle ID 的，和固定的
    private var candidates: [String] {
        var ids: [String] = []
        if let b = Bundle.main.bundleIdentifier { ids.append(b + ".save") }
        if !ids.contains(Self.fixedID) { ids.append(Self.fixedID) }
        return ids
    }

    /// App 启动时调用一次：登记后台任务的处理方法（系统要求在启动完成之前登记）
    func registerAtLaunch() {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *) else { return }
        for id in candidates {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                Task { @MainActor in BackgroundRun.shared.adopt(task) }
            }
            if ok { registered.append(id) }
        }
        #endif
    }

    /// 一次保存开始
    func begin() {
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        guard short == .invalid else { return }
        short = UIApplication.shared.beginBackgroundTask(withName: "save") {
            // 系统给的时间用完了：必须马上交还，否则 App 会被结束
            MainActor.assumeIsolated { BackgroundRun.shared.endShort() }
        }
    }

    private func endShort() {
        guard short != .invalid else { return }
        UIApplication.shared.endBackgroundTask(short)
        short = .invalid
    }

    /// 开始下载时调用：申请后台继续。返回有没有申请到
    func startLong(title: String, subtitle: String) -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if task != nil || submitted != nil { return true }
            for id in registered {
                let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
                request.strategy = .fail  // 现在开始不了就算了，不排队
                do {
                    try BGTaskScheduler.shared.submit(request)
                    submitted = id
                    return true
                } catch {
                    continue
                }
            }
        }
        #endif
        return false
    }

    /// 系统开始了我们申请的任务
    private func adopt(_ t: BGTask) {
        submitted = nil
        guard running else {
            t.setTaskCompleted(success: true)  // 保存已经结束了
            return
        }
        task = t
        done = 0
        // 系统要收回（资源紧张，或者用户在系统界面上点了停止）：停掉这次保存
        t.expirationHandler = {
            Task { @MainActor in BackgroundRun.shared.expired() }
        }
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                BackgroundRun.shared.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func expired() {
        guard let t = task else { return }
        task = nil
        ticker?.cancel()
        ticker = nil
        SaveService.shared.say("系统结束了后台任务，已停止这次保存")
        SaveService.shared.cancel()
        t.setTaskCompleted(success: false)
    }

    /// 「下载中 37%」这样的进度文字里的百分比
    private func percent(in line: String) -> Int? {
        guard let end = line.firstIndex(of: "%") else { return nil }
        let digits = line[..<end].reversed().prefix { $0.isNumber }
        return Int(String(digits.reversed()))
    }

    /// 每秒把进度报给系统：系统靠它在灵动岛上画进度，长时间没有进展的任务会被收回
    private func tick() {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask else { return }
        let service = SaveService.shared
        var target = done
        switch service.phase {
        case .parsing:
            target = 50
        case .downloading:
            target = 100 + Int64(percent(in: service.latest) ?? 0) * 4
        case .saving(let index, let total):
            target = 500 + Int64(500 * (index - 1) / max(1, total))
        default:
            break
        }
        done = min(990, max(done + 1, target))
        t.progress.totalUnitCount = 1000
        t.progress.completedUnitCount = done
        t.updateTitle(service.phase.label, subtitle: service.latest)
        #endif
    }

    /// 一次保存结束（成功、失败、取消都要调用）
    func end(success: Bool) {
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        ticker?.cancel()
        ticker = nil
        if let t = task {
            task = nil
            t.setTaskCompleted(success: success)
        }
        if let id = submitted {
            submitted = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
        }
        endShort()
    }
}
