// WindowBGFollow — 窗口背后跟随图片（原生实现）
// 原理：透明 overlay NSWindow 通过 order(.below, relativeTo:) 垫到目标窗口后，
//       AXObserver 监听移动/缩放实时同步 frame，外扩 halo 露出图片边缘形成光晕。

import AppKit
import ApplicationServices
import Darwin
import ImageIO
import UniformTypeIdentifiers

// AXUIElementGetWindow 未暴露给 Swift，经 dlsym 动态获取；符号缺失时安全降级为返回 failure
private let AXUIElementGetWindowFn: (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError = {
    typealias Fn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    for path in ["/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
                 "/System/Library/PrivateFrameworks/Hiservices.framework/Hiservices",
                 "/System/Library/PrivateFrameworks/HIServices.framework/HIServices"] {
        if let h = dlopen(path, RTLD_LAZY), let sym = dlsym(h, "AXUIElementGetWindow") {
            NSLog("AXUIElementGetWindow loaded from \(path)")
            return unsafeBitCast(sym, to: Fn.self)
        }
    }
    NSLog("AXUIElementGetWindow not found, fallback to failure")
    return { _, _ in AXError.failure }
}()

// 光晕外扩像素；0 = 与目标窗口完全重合（不透明窗口下整图不可见，仅圆角缺口透出）
let halo: CGFloat = 0
// overlay 圆角半径，对齐 macOS 26 窗口圆角（约 26px）
let cornerRadius: CGFloat = 26

// MARK: - AXObserver 回调（C 函数指针，不能捕获上下文，经 refcon 取回 tracker）

let axCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon = refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    switch notification as String {
    case "AXWindowMoved", "AXWindowResized":
        tracker.syncFrame()
    case "AXWindowMiniaturized":
        tracker.hideOverlay()
    case "AXWindowDeminiaturized":
        tracker.syncFrame()
        tracker.showOverlay()
    case "AXUIElementDestroyed":
        // 窗口关闭立即重定目标，避免背景残留
        tracker.retarget(to: NSWorkspace.shared.frontmostApplication)
    default:
        break
    }
}

// MARK: - 窗口追踪器

final class WindowTracker: NSObject {
    static let shared = WindowTracker()

    // 每屏一个常驻背景副本：key=屏幕，overlay 永不跨屏移动，避免过屏时 z 序被打散
    private var overlays: [ObjectIdentifier: NSWindow] = [:]
    private var activeOverlay: NSWindow?
    private var targetNumber: UInt32?          // 目标窗口 CGWindowNumber（全局有效）
    private var observer: AXObserver?          // 必须强持有，否则 RunLoop source 释放、回调静默死亡
    private var observedPID: pid_t = 0
    private var accessibilityGranted = false
    // 降采样后的背景图（按最大屏尺寸解码，控制内存），含 mtime 用于热重载
    private var bgImage: CGImage?
    private var bgImagePath: URL?
    private var bgImageMtime: Date?
    // app 过滤配置（白名单/黑名单），热生效
    private var whitelist: [String] = []
    private var blacklist: [String] = []
    private var configMtime: Date?

    func start() {
        reloadResources()
        requestAccessibility()
        subscribeSystemNotifications()

        // 250ms 兜底巡检：部分 app 不发 AXUIElementDestroyed，关闭检测靠这里兜底
        // （单次开销 = 一次 CGWindowList 拷贝，5Hz 可忽略；AX destroyed 通知命中时立即切换）
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }

        retarget(to: NSWorkspace.shared.frontmostApplication)
        NSLog("WindowBGFollow started, accessibility=\(accessibilityGranted)")
    }

    // MARK: overlay 窗口

    /// 取指定屏的常驻背景副本，不存在则创建（frame 只落在本屏内，永不跨屏移动）
    private func overlay(for screen: NSScreen) -> NSWindow {
        let key = ObjectIdentifier(screen)
        if let win = overlays[key] { return win }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true          // 鼠标穿透，不干扰任何操作
        win.level = .normal                    // order-below 是全局序，normal 层最稳
        win.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]

        // layer-backed 视图：aspect-fill 裁剪填充 + 圆角裁切（内容为降采样后的 bgImage）
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        bg.wantsLayer = true
        bg.layer?.contents = bgImage
        bg.layer?.contentsGravity = .resizeAspectFill
        bg.layer?.masksToBounds = true
        bg.layer?.cornerRadius = cornerRadius
        win.contentView = bg
        overlays[key] = win
        return win
    }

    // MARK: 资源加载（图片 + 配置，均位于 app 所在目录，替换即生效）

    /// 配置目录：标准位置 ~/Library/Application Support/WindowBGFollow（目录不存在则创建）
    private func supportDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowBGFollow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 图片查找顺序（兼容模式）：Application Support → app 同目录 → bundle Resources
    private func resolveImagePath() -> URL? {
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let names = ["bg.jpg", "bg.jpeg", "bg.png"]
        let candidates = names.map { supportDir().appendingPathComponent($0) }
            + names.map { appDir.appendingPathComponent($0) }
            + names.map { Bundle.main.resourceURL!.appendingPathComponent($0) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func reloadResources() {
        // 图片：仅启动时加载一次，固定 720p 基线（最长边 1280px），足够背景用途
        if let path = resolveImagePath() {
            bgImage = downsampledImage(url: path, maxPixel: 1280)
            bgImagePath = path
            for win in overlays.values {
                (win.contentView as? NSView)?.layer?.contents = bgImage
            }
            NSLog("背景图已加载 \(path.path) 基线=720p(1280px)")
        }
        // 配置：白名单/黑名单（bundle id），热生效
        reloadConfig()
    }

    /// 仅重载配置（healthCheck 每 250ms 调用；图片不参与热替换）
    /// 查找顺序（兼容模式）：Application Support → app 同目录
    private func reloadConfig() {
        let candidates = [supportDir().appendingPathComponent("config.json"),
                          Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("config.json")]
        guard let configURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        let cmtime = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
        if cmtime != configMtime {
            configMtime = cmtime
            if let data = try? Data(contentsOf: configURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
                whitelist = obj["whitelist"] ?? []
                blacklist = obj["blacklist"] ?? []
                NSLog("配置已加载 whitelist=\(whitelist.count) blacklist=\(blacklist.count)")
            } else {
                whitelist = []; blacklist = []
            }
        }
    }

    /// ImageIO 缩略图解码，maxPixel 为最长边像素上限
    private func downsampledImage(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// app 过滤：白名单非空=仅白名单生效；否则黑名单内的跳过
    private func isAllowed(_ app: NSRunningApplication) -> Bool {
        if !whitelist.isEmpty { return whitelist.contains(app.bundleIdentifier ?? "") }
        return !blacklist.contains(app.bundleIdentifier ?? "")
    }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityGranted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !accessibilityGranted {
            NSLog("需要辅助功能授权：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 WindowBGFollow")
        }
    }

    // MARK: 目标定位

    /// 前台 app 的 AX 焦点窗口号（主窗口，链接悬停产生的 URL 状态气泡不会成为焦点窗口）
    private func focusedWindowNumber(pid: pid_t) -> UInt32? {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value else { return nil }
        var num: CGWindowID = 0
        guard AXUIElementGetWindowFn(unsafeDowncast(v, to: AXUIElement.self), &num) == .success else { return nil }
        return UInt32(num)
    }

    /// 目标窗口定位：优先 AX 焦点窗口号；兜底 CGWindowList 取 layer 0 且尺寸合理的窗口
    private func findWindowNumber(of app: NSRunningApplication) -> UInt32? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // 状态气泡/悬浮小窗是 Chrome 的独立 layer 0 窗口，尺寸过滤排除（宽 < 200 或高 < 100）
        let normalWindows = list.filter { info in
            (info[kCGWindowLayer as String] as? Int) == 0 &&
            (info[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) &&
            (info[kCGWindowBounds as String] as? [String: Any]).flatMap(cgRect).map { $0.width >= 200 && $0.height >= 100 } ?? false
        }
        if accessibilityGranted, let focused = focusedWindowNumber(pid: app.processIdentifier),
           normalWindows.contains(where: { ($0[kCGWindowNumber as String] as? Int).map({ UInt32($0) }) == focused }) {
            return focused
        }
        return normalWindows.first?[kCGWindowNumber as String] as? UInt32
    }

    /// AX 元素按窗口号精确匹配（供 observer 绑定）
    private func axWindowElement(pid: pid_t, number: UInt32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return nil }
        for w in windows {
            var num: CGWindowID = 0
            if AXUIElementGetWindowFn(w, &num) == .success, num == CGWindowID(number) {
                return w
            }
        }
        return nil
    }

    // MARK: 重定目标（App 切换入口）

    func retarget(to app: NSRunningApplication?) {
        guard let app = app else { return }
        // 白名单/黑名单过滤：不参与的 app 直接隐藏背景
        guard isAllowed(app) else { hideOverlay(); targetNumber = nil; return }
        guard let num = findWindowNumber(of: app) else { hideOverlay(); return }
        // 同目标去重：切换激活时反复回调，跳过无意义的重排序（避免闪现）
        if num == targetNumber, app.processIdentifier == observedPID {
            syncFrame()
            return
        }
        targetNumber = num
        rebindObserver(pid: app.processIdentifier)
        syncFrame()
        showOverlay()
        reorder()
    }

    /// 换绑 AXObserver：移除旧 RunLoop source，为目标的 AX 窗口元素订阅 moved/resized/minimized
    private func rebindObserver(pid: pid_t) {
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            observer = nil
        }
        observedPID = pid
        guard accessibilityGranted, let num = targetNumber,
              let element = axWindowElement(pid: pid, number: num) else { return }

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, axCallback, &newObserver) == .success,
              let obs = newObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXUIElementDestroyedNotification as String] {
            AXObserverAddNotification(obs, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    // MARK: frame 同步

    /// CGWindowBounds 字典（CFDictionary 桥接）→ CGRect，失败返回 nil
    private func cgRect(from dict: [String: Any]) -> CGRect? {
        guard let x = (dict["X"] as? NSNumber)?.doubleValue,
              let y = (dict["Y"] as? NSNumber)?.doubleValue,
              let w = (dict["Width"] as? NSNumber)?.doubleValue,
              let h = (dict["Height"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func syncFrame() {
        guard let num = targetNumber,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let raw = list.first(where: {
                  ($0[kCGWindowNumber as String] as? Int).map({ UInt32($0) }) == num
              }),
              let b = cgRect(from: raw[kCGWindowBounds as String] as? [String: Any] ?? [:]) else {
            hideOverlay()
            return
        }
        // CG 左上原点 → NS 左下原点（主屏 origin=(0,0)，maxY 即全局高）
        let nsY = NSScreen.screens[0].frame.maxY - b.maxY
        let targetFrame = NSRect(x: b.origin.x - halo, y: nsY - halo, width: b.width + halo * 2, height: b.height + halo * 2)
        // 目标所在屏决定用哪个常驻副本：overlay 各自钉在自己的屏上，切屏=换副本，不移动任何窗口
        let center = NSPoint(x: targetFrame.midX, y: targetFrame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else {
            hideOverlay()
            return
        }
        let win = overlay(for: screen)
        var switched = false
        if win !== activeOverlay {
            activeOverlay?.orderOut(nil)          // 换副本：旧屏的背景隐藏，新屏副本顶上
            activeOverlay = win
            switched = true
        }
        win.setFrame(targetFrame, display: true)
        if switched { reorder() }                 // 新副本需挂到目标窗口后方才可见
    }

    // MARK: 层级

    /// 垫到目标窗口正后方（窗口号全局有效，跨进程可垫底）
    private func reorder() {
        guard let num = targetNumber, let win = activeOverlay else { return }
        win.order(.below, relativeTo: Int(num))
    }

    func showOverlay() {
        guard targetNumber != nil, activeOverlay != nil else { return }
        // 只用 order(.below) 垫底显示，禁止 orderFront（会把 overlay 抬到所有窗口之上造成闪现）
        reorder()
    }

    func hideOverlay() {
        activeOverlay?.orderOut(nil)
    }

    // MARK: 系统通知

    private func subscribeSystemNotifications() {
        // 拖拽补帧：AXWindowMoved 在部分 app/macOS 26 下拖动结束后才发一次，
        // 检测到鼠标拖拽期间开 60Hz 补帧轮询，松开即停（非拖拽期零开销）
        var isDragging = false
        let dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard isDragging, self?.targetNumber != nil else { return }
            self?.syncFrame()
        }
        RunLoop.main.add(dragTimer, forMode: .eventTracking)   // 拖拽时 main runloop 处于 tracking mode
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { _ in
            isDragging = true
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            isDragging = false
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // 延迟 50ms 等激活动画落位再 retarget，避免部分 app（如企微）切换闪现
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.retarget(to: app)
            }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.retarget(to: NSWorkspace.shared.frontmostApplication)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncFrame()
        }
    }

    // MARK: 兜底巡检（1Hz）

    private func healthCheck() {
        if !accessibilityGranted { requestAccessibility() }
        reloadConfig()   // 配置热生效（图片仅启动时加载，不热替换）
        guard let num = targetNumber, accessibilityGranted else { return }
        // 轻量存活检测：前台 app 的 AX 焦点窗口号是否仍等于目标窗口号，
        // 不一致（关闭/切窗口）即重定目标，单次 AX 调用，免去全量 CGWindowList 拷贝
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        // 焦点暂不可读（动画期等）不算失配，等下轮巡检
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value else { return }
        let focused = unsafeDowncast(v, to: AXUIElement.self)
        var focusedNum: CGWindowID = 0
        if AXUIElementGetWindowFn(focused, &focusedNum) == .success, focusedNum == CGWindowID(num) {
            if activeOverlay?.isVisible != true { showOverlay() }
        } else {
            retarget(to: app)
        }
    }
}

// MARK: - AppDelegate + 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowTracker.shared.start()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // SF Symbol 模板图，自动适配系统深浅色与菜单栏风格
        if let img = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "WindowBGFollow") {
            img.isTemplate = true
            item.button?.image = img
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "退出 WindowBGFollow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 常驻后台，不占 Dock
app.run()
