import SwiftUI
import ServiceManagement

/// Presentation only: both power modes retain AppState's shared stop rules.
struct MenuContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var secondary: Color { .secondary }
    private var hairline: Color { Color.primary.opacity(contrast == .increased ? 0.3 : 0.1) }

    var body: some View {
        materialPanel
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: state.anyAwake)
            .task(id: "\(state.triggerMode.rawValue):\(state.agent.rawValue)") {
                if state.triggerMode == .agentTask && state.canEditSettings { await state.refreshAgentTasks() }
            }
    }

    @ViewBuilder
    private var materialPanel: some View {
        if #available(macOS 26.0, *) {
            Group {
                if reduceTransparency || contrast == .increased {
                    panel.background(Color(NSColor.windowBackgroundColor), in: .rect(cornerRadius: 18))
                } else {
                    panel
                        .glassEffect(.clear, in: .rect(cornerRadius: 18))
                        // Apple's clear glass needs a dimming layer for legibility.
                        .background(.black.opacity(0.3), in: .rect(cornerRadius: 18))
                }
            }
            // Remove the legacy window material behind the single Liquid Glass layer.
            .containerBackground(.clear, for: .window)
            .preferredColorScheme(.dark)
        } else {
            panel.background {
                if reduceTransparency || contrast == .increased {
                    Color(NSColor.windowBackgroundColor)
                }
            }
        }
    }

    private var panel: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .frame(height: panelHeight)
        }
        .frame(width: 360)
        .frame(maxHeight: panelHeight, alignment: .top)
        // A menu window proposes its full available height. Keep the content's
        // intrinsic height instead of centering it in a 720-point empty panel.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var panelHeight: CGFloat { min(720, (NSScreen.main?.visibleFrame.height ?? 900) - 60) }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 6) {
                modeControls
                Label("合盖优先熄屏，开盖恢复常亮。", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("合盖保活时，内置与外接屏幕都会熄灭。屏幕常亮请求在开盖后恢复。")
            }
            stopConditions
            safeguards
            if let message = state.stopMessage {
                Label(stopSummary(message), systemImage: "pause.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
            }
            footer
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("KeepAwakeMac")
                    .font(.system(size: 14, weight: .semibold))
                if state.anyAwake {
                    Text("电量 \(state.batteryPercent)% · \(thermalText)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            Text(statusTitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        if state.isBusy { return "处理中" }
        if state.anyAwake { return "保活中" }
        if case .failed = state.status, !state.needsHelperApproval { return "待确认" }
        return "未开启"
    }

    private var modeControls: some View {
        VStack(spacing: 0) {
            modeRow(title: "合盖保活", subtitle: lidSubtitle, symbol: "laptopcomputer",
                    isOn: Binding(get: { state.status.isOn }, set: { _ in Task { await state.toggle() } }))
            if case .failed(let message) = state.status {
                if state.needsHelperApproval {
                    permissionNotice
                } else {
                    failureNotice(title: "合盖保活未能完成", message: message)
                        .padding([.horizontal, .bottom], 14)
                }
            }
            Divider().padding(.leading, 35)
            modeRow(title: "屏幕常亮", subtitle: screenSubtitle, symbol: "sun.max",
                    isOn: Binding(get: { state.screenAwake }, set: { enabled in
                        Task { await state.setScreenAwake(enabled) }
                    }))
            if let error = state.screenError {
                failureNotice(title: "屏幕常亮未能开启", message: error)
                    .padding([.horizontal, .bottom], 14)
            }
        }
    }

    private func modeRow(title: String, subtitle: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(isOn.wrappedValue ? Color.primary : secondary)
                .frame(width: 24, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .accessibilityLabel(title)
                .disabled(state.isBusy)
                .help(title == "合盖保活" ? "合盖后继续运行任务，同时关闭显示器" : "防止闲置熄屏与系统睡眠；合盖时让位于熄屏")
        }
        .padding(.vertical, 6)
    }

    private var lidSubtitle: String {
        switch state.status {
        case .activating: return "正在开启，请稍候…"
        case .deactivating: return "正在恢复正常睡眠…"
        case .active: return "合上屏幕，任务继续运行"
        default: return "合上屏幕，任务继续运行"
        }
    }

    private var screenSubtitle: String {
        if state.screenChanging { return "正在开启，请稍候…" }
        if state.screenAwake && !state.screenHeld { return "常亮已暂停 · 等待确认开盖" }
        return "保持屏幕点亮，Mac 不自动睡眠"
    }

    private var permissionNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield").font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("需要允许后台活动").font(.system(size: 11, weight: .medium))
                Text("在系统设置中允许后，再开启此开关。")
                    .font(.system(size: 10)).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            Button { SMAppService.openSystemSettingsLoginItems() } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(QuietButtonStyle())
            .foregroundStyle(.primary)
            .accessibilityLabel("打开系统设置，允许 KeepAwakeMac 后台活动")
            .help("系统设置 → 通用 → 登录项与扩展 → 允许 KeepAwakeMac 后台活动")
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private func failureNotice(title: String, message: String) -> some View {
        DisclosureGroup {
            Text(message).font(.system(size: 10.5)).foregroundStyle(secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } label: {
            Label(title, systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(.red)
        }
    }

    private var stopConditions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $state.triggerMode) {
                ForEach(AppState.TriggerMode.allCases) { Text(modeTitle($0)).tag($0) }
            } label: { Text("停止条件").frame(width: 60, alignment: .leading) }
                .pickerStyle(.menu).controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!state.canEditSettings)
                .accessibilityLabel("停止条件")
                .accessibilityHint("同时作用于两种保活")
                .help("所选停止条件同时关闭合盖保活和屏幕常亮。")
            if state.triggerMode == .timer {
                HStack {
                    Text("持续时间").foregroundStyle(secondary)
                    Spacer()
                    ValueStepper(value: $state.timerHours, range: 1...24, suffix: "小时", name: "持续时间")
                }
                .disabled(!state.canEditSettings)
            }
            if state.triggerMode == .process {
                VStack(alignment: .leading, spacing: 6) {
                    Text("应用名称").font(.system(size: 11)).foregroundStyle(secondary)
                    TextField("输入应用名称或 Bundle ID", text: $state.processName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("要等待退出的应用名称")
                    Text("等待应用退出；Agent 任务请使用上方专用选项。")
                        .font(.system(size: 10)).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!state.canEditSettings)
            }
            if state.triggerMode == .agentTask {
                agentControls
                    .disabled(!state.canEditSettings)
            }
            if !state.canEditSettings {
                Label("关闭两个开关后，可调整停止条件与保护。", systemImage: "lock")
                    .font(.system(size: 10)).foregroundStyle(secondary)
            }
        }
    }

    private var agentControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(selection: $state.agent) {
                ForEach(AgentTask.Agent.allCases) { Text($0.rawValue).tag($0) }
            } label: { Text("Agent").frame(width: 60, alignment: .leading) }
                .pickerStyle(.menu).controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Agent 类型")
            HStack {
                Text("等待的任务").font(.system(size: 11)).foregroundStyle(secondary)
                Spacer()
                Button { Task { await state.refreshAgentTasks() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise").font(.system(size: 10.5))
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(state.loadingTasks)
                .accessibilityLabel("刷新正在运行的 Agent 任务")
            }
            if state.loadingTasks {
                HStack {
                    Text("正在读取任务…").foregroundStyle(secondary)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                        .frame(width: 38, height: 7)
                }
                .font(.system(size: 11)).padding(11)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("正在读取任务")
            } else if let error = state.taskError {
                failureNotice(title: "暂时无法读取任务，请刷新重试", message: error)
            } else if state.agentTasks.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("还没有运行中的任务").font(.system(size: 11, weight: .medium))
                    Text("先在 \(state.agent.rawValue) 中开始任务，再点刷新。")
                        .font(.system(size: 10.5)).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            } else {
                Picker("等待的任务", selection: $state.selectedTaskID) {
                    ForEach(state.agentTasks) { Text($0.title).tag($0.id) }
                }
                    .pickerStyle(.menu).labelsHidden().controlSize(.regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .accessibilityLabel("等待的任务")
                    .help(selectedTaskTitle)
                Text("仅等待所选任务，结束后关闭两种保活。")
                    .font(.system(size: 10)).foregroundStyle(secondary)
            }
        }
    }

    private var selectedTaskTitle: String {
        state.agentTasks.first { $0.id == state.selectedTaskID }?.title ?? "选择一个任务"
    }

    private var safeguards: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading("安全保护")
            HStack {
                Label("最低电量", systemImage: "battery.25percent")
                    .labelStyle(.titleOnly)
                Spacer()
                ValueStepper(value: $state.batteryFloorPercent, range: 5...80, suffix: "%", name: "最低电量")
            }
            HStack {
                Text("过热时自动停止")
                Spacer()
                Toggle("过热时自动停止", isOn: $state.thermalAutoStopEnabled)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("过热时自动停止")
            }
        }
        .disabled(!state.canEditSettings)
        .help("电量到达下限或温度达到严重过热等级时，两种保活都会停止。")
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Rectangle().fill(hairline).frame(height: 1)
            HStack {
                Toggle("登录时启动", isOn: $state.launchAtLogin)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .font(.system(size: 10.5)).foregroundStyle(secondary)
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    HStack(spacing: 5) {
                        Text("退出")
                        Text("⌘Q").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 10.5))
                    .padding(.vertical, 4)
                }
                .buttonStyle(QuietButtonStyle()).foregroundStyle(secondary)
                .keyboardShortcut("q")
                .accessibilityLabel("退出 KeepAwakeMac")
            }
        }
    }

    private func sectionHeading(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(secondary) }
        }
    }

    private func modeTitle(_ mode: AppState.TriggerMode) -> String {
        switch mode {
        case .manual: return "手动关闭"
        case .timer: return "倒计时结束"
        case .agentTask: return "Agent 任务完成"
        case .process: return "指定应用退出"
        case .chargingOnly: return "断开电源适配器"
        }
    }

    private func stopSummary(_ reason: String) -> String {
        if case .failed = state.status { return "已请求停止，请确认上方错误。" }
        if reason.hasSuffix("task finished") { return "所选任务已结束，保活已停止。" }
        if reason == "Timer elapsed" { return "倒计时结束，保活已停止。" }
        if reason == "Selected app exited" { return "指定应用已退出，保活已停止。" }
        if reason == "Power adapter disconnected" { return "已断开电源，保活已停止。" }
        if reason.hasPrefix("Battery at") { return "电量已到下限，保活已停止。" }
        if reason == "Thermal state: critical" { return "温度过高，保活已停止。" }
        if reason == "Agent task stopped or failed" { return "任务已中止或失败，保活已停止。" }
        return "保活已停止：\(reason)"
    }

    private var thermalText: String {
        switch state.thermalState {
        case .nominal: return "温度正常"
        case .fair: return "温度稍高"
        case .serious: return "温度较高"
        case .critical: return "温度过高"
        @unknown default: return "温度未知"
        }
    }
}

private struct ValueStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String
    let name: String

    var body: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - 1) } label: {
                Image(systemName: "minus").font(.system(size: 10, weight: .medium)).frame(width: 28, height: 28)
            }
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("减少\(name)")
            Text("\(value)\(suffix)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(minWidth: 46)
                .accessibilityLabel("\(name) \(value)\(suffix)")
            Button { value = min(range.upperBound, value + 1) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .medium)).frame(width: 28, height: 28)
            }
            .disabled(value >= range.upperBound)
            .accessibilityLabel("增加\(name)")
        }
        .buttonStyle(QuietButtonStyle())
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: configuration.isPressed)
    }
}
