import AppKit
import AutoThemeSwitcherCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            readings
            Divider()
            automationSettings
            Divider()
            manualControls
            Divider()
            integrationControls
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 400)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: controller.menuBarSymbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                Text("Auto Theme Switcher")
                    .font(.headline)
                Spacer()
                if controller.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(controller.hasError ? .red : .secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var readings: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            statusRow("当前模式", controller.modeLabel)
            statusRow("实时光强", luxText(controller.currentLux))
            statusRow("平滑光强", luxText(controller.smoothedLux))
            statusRow("传感器", controller.sensorStatus)
            statusRow("VS Code", controller.vscodeStatus)
            statusRow("Ghostty", controller.ghosttyStatus)
            if let progress = controller.candidateProgressLabel {
                statusRow("候选切换", progress)
            }
        }
        .font(.callout)
    }

    private var automationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("自动切换", isOn: Binding(
                get: { controller.preferences.automaticEnabled },
                set: { controller.setAutomaticEnabled($0) }
            ))

            HStack {
                Text("进入室内")
                Spacer()
                EditableWholeNumberField(
                    placeholder: "1000",
                    value: Binding(
                        get: { controller.preferences.indoorThreshold },
                        set: { controller.preferences.indoorThreshold = $0 }
                    )
                )
                Text("lux")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("进入强光")
                Spacer()
                EditableWholeNumberField(
                    placeholder: "5000",
                    value: Binding(
                        get: { controller.preferences.outdoorThreshold },
                        set: { controller.preferences.outdoorThreshold = $0 }
                    )
                )
                Text("lux")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("稳定时间")
                Spacer()
                Stepper(
                    value: Binding(
                        get: { controller.preferences.stabilitySeconds },
                        set: { controller.preferences.stabilitySeconds = $0 }
                    ),
                    in: 1 ... 60,
                    step: 1
                ) {
                    Text("\(Int(controller.preferences.stabilitySeconds)) 秒")
                        .monospacedDigit()
                }
            }

            HStack {
                Text("最短驻留")
                Spacer()
                EditableWholeNumberField(
                    placeholder: "15",
                    value: Binding(
                        get: { controller.preferences.minimumDwellSeconds },
                        set: { controller.preferences.minimumDwellSeconds = $0 }
                    )
                )
                Text("秒")
                    .foregroundStyle(.secondary)
            }

            if let message = controller.preferences.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .disabled(controller.isWorking)
    }

    private var manualControls: some View {
        HStack {
            Button {
                controller.switchManually(to: .light)
            } label: {
                Label("亮色", systemImage: "sun.max.fill")
            }
            .themeSelectionStyle(isSelected: controller.displayedMode == .light)

            Button {
                controller.switchManually(to: .dark)
            } label: {
                Label("暗色", systemImage: "moon.fill")
            }
            .themeSelectionStyle(isSelected: controller.displayedMode == .dark)

            Spacer()
        }
        .disabled(controller.isWorking)
    }

    private var integrationControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("登录时启动", isOn: Binding(
                get: { controller.preferences.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))

            Text("系统状态：\(controller.loginItemStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("安装或修复集成") {
                    controller.installIntegration()
                }
                Button("恢复并停用") {
                    controller.restoreAndDisable()
                }
            }

            HStack {
                Button("打开 VS Code 配置") {
                    controller.openVSCodeConfiguration()
                }
                Button("打开 Ghostty 配置") {
                    controller.openGhosttyConfiguration()
                }
            }

            Button("打开备份目录") {
                controller.openBackupDirectory()
            }
        }
        .disabled(controller.isWorking)
    }

    private var footer: some View {
        HStack {
            Button("复制诊断摘要") {
                controller.copyDiagnostics()
            }
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func luxText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded())) lux"
    }
}

private struct EditableWholeNumberField: View {
    @Binding private var value: Double
    private let placeholder: String
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(placeholder: String, value: Binding<Double>) {
        self.placeholder = placeholder
        _value = value
        _text = State(initialValue: Self.formatted(value.wrappedValue))
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
            .focused($isFocused)
            .onChange(of: text) { newText in
                let candidate = newText.trimmingCharacters(in: .whitespaces)
                guard !candidate.isEmpty, let parsed = Double(candidate), parsed.isFinite else {
                    return
                }
                value = parsed
            }
            .onChange(of: value) { newValue in
                guard !isFocused else { return }
                text = Self.formatted(newValue)
            }
            .onChange(of: isFocused) { focused in
                guard !focused else { return }
                // 空白和未完成输入只作为编辑中的临时状态；离开输入框时恢复最后一个有效值。
                text = Self.formatted(value)
            }
            .onSubmit {
                text = Self.formatted(value)
            }
    }

    private static func formatted(_ value: Double) -> String {
        guard value.isFinite,
              value >= Double(Int.min),
              value <= Double(Int.max)
        else {
            return String(value)
        }
        return String(Int(value.rounded()))
    }
}

private extension View {
    @ViewBuilder
    func themeSelectionStyle(isSelected: Bool) -> some View {
        if isSelected {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
