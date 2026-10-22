import ClockKit
import Foundation
import WatchKit
import os

/// 「静帧 → 动画」交接的健康管理：发现卡住就自己补救，并留一份真机诊断日志。
///
/// 卡住的成因（2026-10-19 在模拟器复现）：表盘进程向素材应用要数据时，素材应用若在交接中途被系统
/// 杀掉（真机后台的内存与 CPU 额度远比模拟器紧，每次交出的 80 帧动画又很重），表盘就停在静帧或空白
/// 占位上，而且不再主动重试；只有打开素材应用、由它调用 reloadTimeline 才恢复。这里把「打开应用
/// 再退出」自动化，分三层：
///
///   1. 看门狗   交出静帧后 8 秒内表盘还没来要动画条目，就 extendTimeline 催一次；再 8 秒仍没有，
///              reloadTimeline 整条重载。用 performExpiringActivity 向系统争取这十几秒的后台时间。
///   2. 后台自愈 约每 30 分钟的后台刷新：上次交接没完成（进程中途被杀，看门狗也跟着没了），或已经
///              一小时以上没交过动画（表盘可能在没有任何回调的情况下丢了视图），就整条重载。
///   3. 诊断日志 每次回调、交接、补救都记一行，素材应用首页显示最近 40 条，真机卡住时截图即可定位。
enum HandoffHealth {
    static let animationID = "frames"

    private static let defaults = UserDefaults.standard
    private static let logger = Logger(subsystem: "p3r.liveclock", category: "自愈")
    private static let kPendingSince = "handoff.pendingSince"      // 交出静帧、还没交出动画的时刻
    private static let kLastDelivered = "handoff.lastDelivered"    // 最近一次交出动画条目
    private static let kEvents = "diag.events"
    private static let lock = NSLock()

    /// 两次检查的间隔；后台刷新的周期；多久没交过动画就例行重载
    static var watchdogDelay: TimeInterval { debugNumber("debug.watchdogSeconds") ?? 8 }
    static var refreshInterval: TimeInterval { debugNumber("debug.refreshSeconds") ?? 30 * 60 }
    static var staleAfter: TimeInterval { debugNumber("debug.staleSeconds") ?? 60 * 60 }

    // MARK: - 诊断日志

    static func record(_ text: String) {
        let line = "\(timeFormatter.string(from: Date()))  \(footprintMB()) MB  \(text)"
        logger.notice("\(line, privacy: .public)")
        lock.lock(); defer { lock.unlock() }
        var events = defaults.stringArray(forKey: kEvents) ?? []
        events.append(line)
        if events.count > 40 { events.removeFirst(events.count - 40) }
        defaults.set(events, forKey: kEvents)
    }

    /// 最近的事件，新的在前
    static var events: [String] { (defaults.stringArray(forKey: kEvents) ?? []).reversed() }
    static var pendingSince: Date? { defaults.object(forKey: kPendingSince) as? Date }
    static var lastDelivered: Date? { defaults.object(forKey: kLastDelivered) as? Date }

    // MARK: - 交接状态（由数据源调用）

    /// 表盘一来要数据就记下「交接开始」；交出动画才清除。进程若在交出静帧之前就被杀
    /// （模拟器里复现出的空白占位），也会留下这个标记，后台自愈据此补救。
    static func requestStarted() {
        if pendingSince == nil { defaults.set(Date(), forKey: kPendingSince) }
    }

    static func stillDelivered() {
        if pendingSince == nil { defaults.set(Date(), forKey: kPendingSince) }
        record("交出静帧，等表盘来要动画条目")
        scheduleRefresh()
        watch()
    }

    static func animationDelivered() {
        defaults.removeObject(forKey: kPendingSince)
        defaults.set(Date(), forKey: kLastDelivered)
        record("交出动画条目，交接完成")
    }

    // MARK: - 第 1 层：看门狗

    private static func isPending(olderThan seconds: TimeInterval) -> Bool {
        guard let since = pendingSince else { return false }
        return Date().timeIntervalSince(since) >= seconds
    }

    private static func watch() {
        let delay = watchdogDelay
        DispatchQueue.global(qos: .utility).async {
            // 后台进程交完数据很快会被挂起，计时器跟着停；向系统争取一点时间把两步检查做完。
            ProcessInfo.processInfo.performExpiringActivity(withReason: "等待动画交接完成") { expired in
                guard !expired else { return }
                for step in 1...2 {
                    Thread.sleep(forTimeInterval: delay)
                    guard isPending(olderThan: delay - 1) else { return }
                    DispatchQueue.main.sync {
                        if step == 1 {
                            record("看门狗：表盘迟迟没来要动画条目，催一次（extendTimeline）")
                            animationComplications().forEach { CLKComplicationServer.sharedInstance().extendTimeline(for: $0) }
                        } else {
                            record("看门狗：仍未交出动画，整条重载（reloadTimeline）")
                            reloadAll()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 第 2 层：后台自愈

    static func scheduleRefresh() {
        let date = Date().addingTimeInterval(refreshInterval)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date, userInfo: nil) { error in
            if let error { record("预约后台刷新失败：\(error.localizedDescription)") }
        }
    }

    /// 后台刷新与应用被拉起时都走这里
    static func backgroundCheck(reason: String) {
        if isPending(olderThan: 10) {
            record("\(reason)：上次交接未完成，整条重载")
            reloadAll()
        } else if let last = lastDelivered, Date().timeIntervalSince(last) < staleAfter {
            record("\(reason)：交接正常（上次交出动画 \(timeFormatter.string(from: last))），不动")
        } else {
            record("\(reason)：超过 \(Int(staleAfter / 60)) 分钟没交过动画，例行重载")
            reloadAll()
        }
        scheduleRefresh()
    }

    // MARK: - 调试开关（只用于模拟器验证）
    //
    // 启动参数 -p3rDebug key=value 会写进持久设置，供之后由表盘在后台拉起的进程读取：
    //   dropFutureArmed=1   丢弃下一次「后台」的动画条目请求，制造只拿到静帧的卡死
    //   refreshSeconds=60   后台刷新周期    staleSeconds=30   多久没交过动画就例行重载
    //   watchdogSeconds=8   看门狗间隔      reset             清除全部调试设置
    static func applyDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-p3rDebug"), i + 1 < args.count else { return }
        for item in args[(i + 1)...].prefix { !$0.hasPrefix("-") } {
            if item == "reset" {
                for k in ["debug.dropFutureArmed", "debug.refreshSeconds", "debug.staleSeconds", "debug.watchdogSeconds"] { defaults.removeObject(forKey: k) }
                record("调试：清除全部调试设置")
                continue
            }
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "dropFutureArmed" { defaults.set(kv[1] == "1", forKey: "debug.dropFutureArmed") }
            else if let v = Double(kv[1]) { defaults.set(v, forKey: "debug.\(kv[0])") }
            record("调试：\(kv[0]) = \(kv[1])")
        }
    }

    /// 后台请求时消耗一次「丢弃动画条目」开关
    static func consumeDropFuture() -> Bool {
        guard defaults.bool(forKey: "debug.dropFutureArmed"), WKApplication.shared().applicationState != .active else { return false }
        defaults.set(false, forKey: "debug.dropFutureArmed")
        return true
    }

    // MARK: - 工具

    static func reloadAll() {
        let server = CLKComplicationServer.sharedInstance()
        server.reloadComplicationDescriptors()
        for complication in server.activeComplications ?? [] { server.reloadTimeline(for: complication) }
    }

    private static func animationComplications() -> [CLKComplication] {
        (CLKComplicationServer.sharedInstance().activeComplications ?? []).filter { $0.identifier == animationID }
    }

    private static func debugNumber(_ key: String) -> TimeInterval? {
        let v = defaults.double(forKey: key)
        return v > 0 ? v : nil
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// 进程物理内存占用（系统按它决定是否杀进程）
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}

/// 接收后台刷新；应用因任何原因被拉起时也顺带检查一次交接状态。
final class AppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        HandoffHealth.applyDebugArguments()
        HandoffHealth.record("素材应用进程启动")
        HandoffHealth.scheduleRefresh()
        if HandoffHealth.pendingSince != nil {
            // 上一个进程交出静帧后就没了下文：多半是交接中途被杀。给表盘几秒自己来要，不来再补救。
            DispatchQueue.main.asyncAfter(deadline: .now() + HandoffHealth.watchdogDelay) {
                if HandoffHealth.pendingSince != nil { HandoffHealth.backgroundCheck(reason: "启动检查") }
            }
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                HandoffHealth.backgroundCheck(reason: "后台刷新")
                refresh.setTaskCompletedWithSnapshot(false)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
