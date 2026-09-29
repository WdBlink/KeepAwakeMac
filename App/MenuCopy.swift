/// User-visible copy for the two switches, kept out of the view so the
/// regression checks can assert on the words that actually ship.
///
/// Every sentence here must stay inside what the app really guarantees: it holds
/// an *idle*-sleep display assertion and tells the helper not to issue
/// `pmset displaysleepnow`. It does not override macOS's own lid-close blank,
/// which is not an idle event.
enum MenuCopy {
    static let precedence = "屏幕常亮优先，本工具不会因合盖熄屏。"
    static let precedenceHelp =
        "屏幕常亮开启后，本工具不再请求合盖熄屏；macOS 自身的合盖显示行为不受影响。"

    static let lidActivating = "正在开启，请稍候…"
    static let lidDeactivating = "正在恢复正常睡眠…"
    static let lidActive = "合上屏幕，任务继续运行"

    static let screenChanging = "正在开启，请稍候…"
    static let screenActive = "保持屏幕点亮，Mac 不闲置睡眠"

    static let lidHelp = "合盖后继续运行任务；合盖时是否熄屏由屏幕常亮决定"
    static let screenHelp = "防止闲置熄屏与闲置睡眠，并让本工具在合盖时不请求熄屏"

    /// Phrases from the retired rule where a closed lid outranked the switch.
    /// None of them may come back.
    static let retired = ["合盖优先熄屏", "开盖恢复常亮", "等待确认开盖", "让位于熄屏", "同时关闭显示器"]

    static var all: [String] {
        [precedence, precedenceHelp, lidActivating, lidDeactivating, lidActive,
         screenChanging, screenActive, lidHelp, screenHelp]
    }
}
