import SwiftUI
import FanCoolCore

struct SettingsView: View {
    static let width: CGFloat = 528
    @ObservedObject var model: FanModel
    var snapshotMode = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape").font(.title2).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("设置").font(.title2.bold())
                    Text("智能策略与后台服务").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button("完成", action: model.closeSettings).buttonStyle(PillButton()).disabled(model.busy).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("close-settings")
            }.padding(22)
            if let notice = model.settingsNotice {
                Text(notice).font(.system(size: 12)).foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 14)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("settings-notice")
            }
            if snapshotMode { sections }
            else { ScrollView { sections.background(TransparentScrollBackground().frame(width: 0, height: 0).accessibilityHidden(true)) } }
        }.frame(width: Self.width, height: snapshotMode ? 1320 : 710, alignment: .top).foregroundStyle(Palette.ink).background(Palette.background)
            .interactiveDismissDisabled(model.busy)
    }
    private var sections: some View {
        VStack(spacing: 16) {
            strategy
            authorization
            safety
            diagnostics
            Text("FanCool \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.8.7")")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.padding(.horizontal, 22).padding(.bottom, 22)
    }
    private var strategy: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("智能模式策略").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("已保存：\(model.preferredProfile.title)").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 4) {
                ForEach(SmartProfile.allCases, id: \.self) { profile in
                    let selected = model.draftProfile == profile
                    Button { model.draftProfile = profile } label: {
                        HStack(spacing: 7) {
                            Image(systemName: profile.symbol).font(.system(size: 16))
                            Text(profile.title).font(.system(size: 14, weight: .semibold))
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                                .opacity(selected ? 1 : 0).accessibilityHidden(true)
                        }.foregroundStyle(selected ? Palette.accent : Palette.secondary)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(selected ? AnyShapeStyle(Palette.selection) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Palette.accent.opacity(0.65) : Color.clear, lineWidth: 1.2))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).disabled(model.busy)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("profile-\(profile.rawValue)")
                }
            }.padding(4).background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
            Text(model.draftProfile.summary).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            SmartCurvePreview(profile: model.draftProfile)
            HStack {
                ForEach([60.0, 70, 80, 90], id: \.self) { temperature in
                    VStack(spacing: 4) {
                        Text("\(Int(temperature))°C").foregroundStyle(Palette.secondary)
                        Text("\(Int(SmartFanPolicy.curvePercentage(at: temperature, profile: model.draftProfile).rounded()))%")
                            .fontWeight(.semibold)
                    }.font(.system(size: 11)).monospacedDigit().frame(maxWidth: .infinity)
                }
            }
            Text("百分比按各自最大转速计算。曲线为实验性偏好，不保证具体温度或噪音；三档共用高温保护。")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("恢复默认") { model.draftProfile = .defaultProfile }.buttonStyle(.plain)
                    .foregroundStyle(Palette.secondary).disabled(model.busy).accessibilityIdentifier("reset-profile")
                Spacer()
                Button(model.control.smartEnabled ? "保存并应用" : "保存策略", action: model.saveProfile)
                    .buttonStyle(PillButton()).disabled(!model.canSaveProfile).accessibilityIdentifier("save-profile")
            }
            Text(model.control.smartEnabled ? "只调整当前的智能风扇；手动风扇保持原目标，降速等待后平缓过渡。" : "保存后，下次启用智能模式时生效；不会自动接管风扇。")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }.settingsCard()
    }
    private var authorization: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("后台授权").font(.system(size: 15, weight: .semibold))
                Spacer()
                Label(model.authorized ? "已授权" : "调速需授权", systemImage: model.authorized ? "checkmark.shield" : "lock.shield")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
            }
            Text("读取转速和传感器无需管理员权限。安装或更新调速后台时，请在 macOS 弹窗中完成管理员认证，FanCool 不接收或保存密码。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.authorized ? "检查连接" : model.authorizationTitle, action: model.authorize)
                    .buttonStyle(PillButton()).disabled(model.busy).accessibilityIdentifier("authorize")
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("移除后台服务…", role: .destructive, action: model.uninstallHelper)
                    .buttonStyle(.plain).foregroundStyle(.red).disabled(!model.canRemoveHelper).accessibilityIdentifier("remove-helper")
            }
            Text("无需辅助功能、屏幕录制、完全磁盘访问、摄像头、麦克风或网络权限。")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }.settingsCard()
    }
    private var safety: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("保护与启动行为").font(.system(size: 15, weight: .semibold))
            Label("智能温度达到 90°C 时全速；持续高温或严重热压力时交回系统。", systemImage: "thermometer.high")
            Label("主程序退出、失联或睡眠时，请求恢复系统控制。", systemImage: "shield.lefthalf.filled")
            Label("启动默认启用已保存的智能策略；未授权或检查不通过时由系统管理。", systemImage: "power")
            Text("以上保护固定开启，静音策略也不会关闭保护。")
                .foregroundStyle(Palette.secondary)
        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).settingsCard()
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("诊断与控制").font(.system(size: 15, weight: .semibold))
            HStack {
                Button("导出最近调速日志…", action: model.exportWriteLog).buttonStyle(PillButton()).disabled(model.busy || !model.authorized)
                    .accessibilityIdentifier("export-write-log")
                Spacer()
                Button("全部恢复系统", action: model.restore).buttonStyle(PillButton()).disabled(model.busy)
                    .accessibilityIdentifier("restore-all")
            }
        }.settingsCard()
    }
}

private extension View {
    func settingsCard() -> some View {
        self.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 15))
    }
}

struct SmartCurvePreview: View {
    let profile: SmartProfile
    var body: some View {
        VStack(spacing: 5) {
            HStack { Text("目标转速曲线"); Spacer(); Text("100%") }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            GeometryReader { geometry in
                let width = geometry.size.width, height = geometry.size.height
                ZStack {
                    Path { path in
                        for fraction in [0.0, 0.5, 1] {
                            path.move(to: CGPoint(x: 0, y: height * fraction))
                            path.addLine(to: CGPoint(x: width, y: height * fraction))
                        }
                    }.stroke(Palette.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    Path { path in
                        for (index, point) in profile.curve.enumerated() {
                            let position = CGPoint(x: (point.temperature - 45) / 45 * width,
                                y: (100 - point.percentage) / 75 * height)
                            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                    }.stroke(Palette.indicator, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }.frame(height: 66)
            HStack { Text("45°C"); Spacer(); Text("90°C") }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(profile.title)目标曲线：\(profile.curveSummary)")
    }
}
