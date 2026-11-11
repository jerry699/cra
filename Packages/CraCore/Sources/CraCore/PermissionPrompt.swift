/// The question Cra's permission sheet asks for a page's request. `kinds` is CraCEF's bit set:
/// 1 camera, 2 microphone, 4 location, 8 notifications, 16 a type CraCEF can't name, and from
/// 1 << 5 Chrome's other types. Notifications ask like the others (Arc asks too; Messenger and
/// the like need them), up to 0.1.27 they were denied without a sheet. Every type has Chrome's
/// own words, so the sheet says what Allow gives (#137: Calendar's sheet said only "a browser
/// permission").
public enum PermissionPrompt {
    /// Chrome's wording (its *_PERMISSION_FRAGMENT strings), in the order the sheet lists them.
    public static let requests: [(kind: UInt, wants: String)] = [
        (8, "显示通知"),
        (1 << 5, "查看复制到剪贴板的文字和图片"),
        (1 << 6, "管理所有显示器上的窗口"),
        (1 << 7, "访问本地网络中的其他设备"),
        (1 << 8, "访问此设备上的其他应用和服务"),
        (1 << 9, "在此页面使用其 Cookie 和网站数据"),
        (1 << 10, "让它嵌入的网站使用其 Cookie 和网站数据"),
        (1 << 11, "使用你电脑上的字体"),
        (1 << 12, "了解你何时正在使用此设备"),
        (1 << 13, "控制和重新编程你的 MIDI 设备"),
        (1 << 14, "下载多个文件"),
        (1 << 15, "覆盖键盘上的某些按键，如 Esc"),
        (1 << 16, "锁定并使用你的鼠标"),
        (1 << 17, "播放受保护的内容"),
        (1 << 18, "打开某类链接，如邮件或日历链接"),
        (1 << 19, "创建周围环境的 3D 地图并跟踪相机位置"),
        (1 << 20, "使用虚拟现实设备和数据"),
        (1 << 21, "追踪你的双手"),
        (1 << 22, "使用你的运动传感器"),
        (1 << 23, "在此设备上存储文件"),
        (1 << 24, "使用你的账户登录网站"),
        (1 << 25, "滚动和缩放共享标签页的内容"),
        (1 << 26, "安装网络应用"),
        (1 << 27, "编辑此设备上的文件"),
        (1 << 28, "自动登录"),
    ]

    public static func message(origin: String, kinds: UInt) -> String {
        var devices: [String] = []
        if kinds & 1 != 0 { devices.append("摄像头") }
        if kinds & 2 != 0 { devices.append("麦克风") }
        if kinds & 4 != 0 { devices.append("位置") }
        var wants = devices.isEmpty ? [] : ["使用你的\(list(devices))"]
        wants += requests.filter { kinds & $0.kind != 0 }.map(\.wants)
        if kinds & 16 != 0, !wants.isEmpty { wants.append("使用其他浏览器权限") }
        return wants.isEmpty ? "\(origin) 正在请求浏览器权限"
                             : "\(origin) 想要\(list(wants))"
    }

    /// "a", "a和b", "a、b和c".
    private static func list(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: "、") + " 和 " + last
    }
}
