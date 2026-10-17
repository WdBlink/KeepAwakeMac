/// User-visible copy for the two switches, kept out of the view so the
/// regression checks can assert on the words that actually ship.
///
/// Every sentence here must stay inside what the app really guarantees: it holds
/// an *idle*-sleep display assertion and tells the helper not to issue
/// `pmset displaysleepnow`. It does not override macOS's own lid-close blank,
/// which is not an idle event — so nothing here claims the switch "outranks"
/// anything macOS does on its own.
enum MenuCopy {
    static let precedence = "屏幕常亮开启后，本工具不再请求熄屏。"
    static let precedenceHelp =
        "后台服务确认后，本工具不再请求合盖熄屏；失败时会显示警告。不会唤醒已熄灭的屏幕，也不改变 macOS 自身的合盖显示行为。"

    static let lidActivating = "正在开启，请稍候…"
    static let lidDeactivating = "正在恢复正常睡眠…"
    static let lidActive = "合上屏幕，任务继续运行"

    static let screenEnabling = "正在开启，请稍候…"
    static let screenDisabling = "正在关闭，请稍候…"
    static let screenActive = "防止闲置熄屏与闲置睡眠"

    static let lidHelp = "合盖后继续运行任务；屏幕常亮控制本工具的熄屏请求，不改变 macOS 自身行为"
    static let screenHelp = "防止闲置熄屏与闲置睡眠，并让本工具在合盖时不请求熄屏"

    static let screenWarningTitle = "合盖后仍可能熄屏"

    /// Phrases from the retired rule where a closed lid outranked the switch.
    /// None of them may come back. `FeatureCheck` scans every shipped source and
    /// document for these, not just this file — a copy constant is only a copy
    /// constant if something reads it.
    static let retired = ["合盖优先熄屏", "开盖恢复常亮", "等待确认开盖", "让位于熄屏", "同时关闭显示器",
                          "屏幕常亮请求在开盖后恢复", "内置与外接屏幕都会熄灭"]

    /// Every constant here, by name, so a check can prove each one actually
    /// ships instead of sitting unread in this file.
    static var all: [(name: String, text: String)] {
        [("precedence", precedence), ("precedenceHelp", precedenceHelp),
         ("lidActivating", lidActivating), ("lidDeactivating", lidDeactivating),
         ("lidActive", lidActive), ("screenEnabling", screenEnabling),
         ("screenDisabling", screenDisabling), ("screenActive", screenActive),
         ("lidHelp", lidHelp), ("screenHelp", screenHelp),
         ("screenWarningTitle", screenWarningTitle)]
    }
}
