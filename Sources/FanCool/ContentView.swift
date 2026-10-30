import SwiftUI
import FanCoolCore

enum Palette {
    static let accent = Color(red: 15.0 / 255, green: 96.0 / 255, blue: 202.0 / 255)
    static let cyan = Color(red: 23.0 / 255, green: 202.0 / 255, blue: 242.0 / 255)
    static let deepBlue = Color(red: 20.0 / 255, green: 64.0 / 255, blue: 185.0 / 255)
    static let selection = LinearGradient(colors: [Color(red: 201.0 / 255, green: 224.0 / 255, blue: 255.0 / 255), Color(red: 211.0 / 255, green: 246.0 / 255, blue: 252.0 / 255)], startPoint: .leading, endPoint: .trailing)
    static let indicator = LinearGradient(stops: [.init(color: deepBlue, location: 0), .init(color: Color(red: 7.0 / 255, green: 112.0 / 255, blue: 205.0 / 255), location: 0.82), .init(color: cyan, location: 1)], startPoint: .leading, endPoint: .trailing)
    static let ink = Color(red: 27.0 / 255, green: 47.0 / 255, blue: 63.0 / 255)
    static let secondary = Color(red: 94.0 / 255, green: 116.0 / 255, blue: 133.0 / 255)
    static let background = Color(red: 241.0 / 255, green: 248.0 / 255, blue: 252.0 / 255)
    static let pale = Color(red: 226.0 / 255, green: 242.0 / 255, blue: 253.0 / 255)
}

enum FanRotorAsset {
    static let image: NSImage? = Bundle.main.url(forResource: "fan-rotor", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
    static let cgImage: CGImage? = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}
struct FanIcon: View {
    var color: Color? = nil
    var angle: Double = 0
    var body: some View {
        Group {
            if let image = FanRotorAsset.image {
                if let color {
                    Image(nsImage: image).renderingMode(.template).resizable().foregroundStyle(color)
                } else {
                    Image(nsImage: image).renderingMode(.original).resizable()
                }
            } else {
                Image(systemName: "fanblades.fill").resizable().foregroundStyle(color ?? Palette.accent)
            }
        }.scaledToFit().rotationEffect(.degrees(angle)).accessibilityHidden(true)
    }
}
struct RotatingFanIcon: View {
    var running: Bool
    var frozen = false
    var role = "panel"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if frozen { FanIcon() }
            else { NativeRotatingFan(spinning: running && !reduceMotion, role: role) }
        }.accessibilityHidden(true)
    }
}
struct LiveFan: View {
    var running: Bool
    var frozen: Bool
    var body: some View {
        ZStack {
            Circle().fill(Palette.pale)
            RotatingFanIcon(running: running, frozen: frozen).padding(6)
        }.frame(width: 38, height: 38)
    }
}
struct PillButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.accent)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Palette.selection.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .overlay(Capsule().stroke(Palette.accent.opacity(0.1), lineWidth: 0.5))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct ContentView: View {
    @ObservedObject var model: FanModel
    var snapshotMode = false
    var onContentHeightChange: ((CGFloat) -> Void)?
    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PanelHeightKey.self, value: ["header": geometry.size.height])
                })
            if snapshotMode { mainContents.frame(maxHeight: .infinity, alignment: .top) }
            else { ScrollView(.vertical) { mainContents.background(TransparentScrollBackground().frame(width: 0, height: 0).accessibilityHidden(true)) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Palette.ink).background(Palette.background).preferredColorScheme(.light)
        .onPreferenceChange(PanelHeightKey.self) { sizes in
            guard let header = sizes["header"], let body = sizes["body"], header > 0, body > 0 else { return }
            onContentHeightChange?(header + body)
        }
        .alert("FanCool", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("知道了", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }
    private var mainContents: some View {
        VStack(spacing: 12) {
            fanGrid
            metrics
            modeSelector
            switch model.selectedMode {
            case .system: systemSummary
            case .smart: smartSummary
            case .manual:
                manualSettings
                if model.isCustom { customCard }
            }
            status
            footer
        }.padding(.horizontal, 16).padding(.bottom, 14)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PanelHeightKey.self, value: ["body": geometry.size.height])
            })
    }
    private var header: some View {
        HStack(spacing: 8) {
            RotatingFanIcon(running: model.snapshot.error == nil && model.snapshot.fans.contains { $0.actual > 0 }, frozen: snapshotMode, role: "header")
                .frame(width: 32, height: 32)
            Text("FanCool").font(.system(size: 25, weight: .bold, design: .rounded))
            Text(model.chip).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Button(action: model.openSettings) {
                Image(systemName: "gearshape").font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.accent)
                    .frame(width: 32, height: 32).background(Palette.selection, in: Circle())
            }.buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("open-settings")
                .accessibilityLabel("设置").help("智能策略、后台授权与诊断")
        }.frame(minHeight: 36)
    }
    private var fanGrid: some View {
        Group {
            if model.snapshot.fans.isEmpty && model.refreshed && model.snapshot.reportedFanCount == 0 {
                Label("此设备未检测到可读取的风扇", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    if model.snapshot.fans.isEmpty {
                        ForEach(0..<2) { id in
                            VStack(alignment: .leading, spacing: 14) {
                                Text("风扇 \(id + 1)").fontWeight(.semibold)
                                Text("— RPM").font(.system(size: 30, weight: .semibold, design: .rounded))
                                Text(model.refreshed ? "暂无可用读数" : "正在连接…").font(.caption).foregroundStyle(Palette.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14))
                        }
                    } else {
                        ForEach(model.snapshot.fans) { fan in FanCard(model: model, fan: fan, frozen: snapshotMode) }
                    }
                }
            }
        }
    }
    private var metrics: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("控制温度 · CPU/GPU 最高", systemImage: "thermometer.medium").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
                Spacer()
                Button { model.showSensors = true } label: { Label("传感器明细", systemImage: "list.bullet.rectangle") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                    .accessibilityIdentifier("sensor-details")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(model.snapshot.temperature.map { String(format: "%.1f°C", $0) } ?? "—")
                    .font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer()
                Label("CPU \(model.snapshot.cpu.map { String(format: "%.1f%%", $0) } ?? "—")", systemImage: "cpu")
                    .font(.system(size: 17, weight: .medium)).monospacedDigit()
            }
            Text(model.snapshot.hottestChipSensor.map { "来源：\($0.name) · \($0.key)，仅明确映射的温度参与控制" } ?? "没有可信控制温度时，仅提供只读监测")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Text("系统热压力：\(model.snapshot.thermalPressure.title)")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
    private var scopeSelector: some View {
        HStack(spacing: 8) {
            Text("控制范围").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                scopeButton("全部风扇", id: -1)
                ForEach(model.snapshot.fans) { fan in scopeButton("风扇 \(fan.id + 1)", id: fan.id) }
            }.padding(3).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 330).disabled(model.busy).accessibilityIdentifier("control-scope")
        }
    }
    private func scopeButton(_ title: String, id: Int) -> some View {
        Button { model.scope = id; model.scopeChanged() } label: {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.scope == id ? Palette.accent : Palette.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(model.scope == id ? AnyShapeStyle(Palette.selection) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(model.scope == id ? .isSelected : [])
            .accessibilityIdentifier("scope-\(id)")
    }
    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("模式").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 4) {
                ForEach(FanMode.allCases, id: \.self) { mode in
                    let selected = model.selectedMode == mode
                    Button { model.selectMode(mode) } label: {
                        Text(mode.rawValue).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(selected ? Palette.accent : Palette.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(selected ? AnyShapeStyle(Palette.selection) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Palette.accent.opacity(0.1) : Color.clear, lineWidth: 0.5))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).disabled(model.busy || (mode == .smart && !model.canStartSmart))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("mode-\(mode)")
                }
            }.padding(4).background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
            Text("当前运行：\(model.currentModeDescription)")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("running-modes")
        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
    private var systemSummary: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "desktopcomputer").foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("由 macOS 管理全部风扇").font(.system(size: 13, weight: .semibold))
                Text("转速随系统散热需求变化，FanCool 只读取实时数据。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.pale.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }
    private var manualSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("手动设置").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("固定目标").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 6) {
                ForEach(FanPreset.manualOptions, id: \.self) { preset in
                    let selected = model.selectedPreset == preset
                    Button { model.select(preset) } label: {
                        VStack(spacing: 7) {
                            Text(preset.rawValue).font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(preset.percent.map { "\(Int($0))%" } ?? "分别设置")
                                .font(.system(size: 12, weight: .medium)).monospacedDigit().opacity(0.75)
                        }
                        .foregroundStyle(selected ? Palette.accent : Palette.ink)
                        .frame(maxWidth: .infinity).frame(height: 60)
                        .background(selected ? AnyShapeStyle(Palette.selection) : AnyShapeStyle(Color.white), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.accent.opacity(selected ? 0.1 : 0.09), lineWidth: selected ? 0.5 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain).disabled(model.busy || (preset != .custom && !model.canAdjust))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("manual-\(preset)")
                        .help(preset == .custom ? "展开设置，点击应用后才修改目标" : "同时设置全部风扇，按各自最大转速计算目标")
                }
            }
            Text(model.selectedPreset == nil ? "请选择预设或自定义；当前运行状态保持不变。" : "低速、均衡、高速和全速同时作用于全部风扇；自定义支持单独控制。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var smartSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("智能温控 · \(model.displayedProfile.title)", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                Spacer()
                if model.control.smartEnabled, let temperature = model.control.filteredTemperature {
                    Text(String(format: "平滑温度 %.1f°C", temperature)).font(.system(size: 11)).monospacedDigit()
                }
            }
            Text(model.displayedProfile.curveSummary)
                .font(.system(size: 11, weight: .medium)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            Text(model.control.smartEnabled ? "升温优先；降温稳定 15 秒后缓慢降速。按各自最大转速计算，分别调节两只风扇。" : "这是偏好曲线，不是 Apple 官方阈值；系统模式不按此曲线工作。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.pale.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }
    private var customCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                Text("自定义转速").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(Int(model.customPercent.rounded()))%")
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                Button(action: model.applyCustom) {
                    if model.busy { ProgressView().controlSize(.small).frame(width: 28, height: 16) }
                    else { Text("应用") }
                }.buttonStyle(PillButton()).disabled(!model.canApplyCustom).keyboardShortcut(.return, modifiers: [])
                    .accessibilityIdentifier("apply-custom")
            }
            scopeSelector
            Text(model.customStateDescription)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                .accessibilityIdentifier("custom-state")
            PercentageSlider(value: $model.customPercent, range: model.percentageRange, enabled: model.canAdjust)
            HStack {
                Text("最低 \(Int(model.minimumPercent))%")
                Spacer()
                Text("100%")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary).monospacedDigit()
            Divider().overlay(Palette.secondary.opacity(0.1))
            HStack(spacing: 16) {
                ForEach(model.targetFans) { fan in
                    Text("风扇 \(fan.id + 1) → \(model.targetRPM(for: fan).map(rpmText) ?? "—") RPM")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                Spacer(minLength: 0)
            }.foregroundStyle(Palette.secondary)
            Text("点击应用才生效；未选中的风扇保持原状态。百分比按各自最大转速计算。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
    private var status: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(model.snapshot.conflictingController == nil && model.snapshot.error == nil ? Palette.accent : .orange)
                .frame(width: 6, height: 6).padding(.top, 5)
            Text(model.status).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if model.demo { Text("演示").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent) }
        }.accessibilityIdentifier("control-status")
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "shield.lefthalf.filled")
            Text(model.authorized || model.demo ? "温控保护 · 退出交回系统" : "只读监测 · 调速需授权")
            Spacer(minLength: 8)
            Text("· 每 2 秒更新")
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
    }
}

struct FanCard: View {
    @ObservedObject var model: FanModel
    let fan: FanReading
    var frozen: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                LiveFan(running: fan.actual > 0, frozen: frozen)
                Text("风扇 \(fan.id + 1)").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 4)
                Text(model.modeTitle(for: fan)).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent).padding(.horizontal, 8).padding(.vertical, 5).background(Palette.pale, in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(Int(fan.actual.rounded()))).font(.system(size: 29, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                Text("RPM").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Spacer(minLength: 4)
                Text(fan.percentage.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Palette.accent).monospacedDigit()
            }
            let target = model.intent(for: fan.id)?.rpm ?? fan.target
            let systemManaged = model.intent(for: fan.id) == nil && (fan.mode == 0 || fan.mode == 3)
            let adjusting = model.isTargetAdjusting(for: fan)
            Text(systemManaged ? "目标：由 macOS 决定" : "\(adjusting ? "调整中" : "目标") \(target.flatMap { FanSpeed.percent(rpm: $0, maximum: fan.maximum) }.map { "\(Int($0.rounded()))%" } ?? "—") · \(target.map(rpmText) ?? "—") RPM")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                .help(adjusting ? "新目标正在生效，等待硬件读回及实际转速稳定；运行模式没有改变。" : "当前目标转速；系统模式由 macOS 决定。")
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine).accessibilityIdentifier("fan-\(fan.id)")
    }
}

struct SensorDetails: View {
    @ObservedObject var model: FanModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("传感器明细").font(.title2.bold())
                    Text("\(model.snapshot.sensors.count) 项可用读数 · 每 2 秒更新").font(.caption).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button("完成") { model.showSensors = false }.keyboardShortcut(.cancelAction)
            }
            Text("控制温度取明确映射 CPU/GPU 温度的最高值，并非整机平均值。只有白名单中的项目参与温控；其他项仅展示，不凭键名前缀猜测 CPU/GPU。映射来源于公开资料，未知物理位置保留键名。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("类型", selection: $model.sensorKindFilter) {
                Text("全部").tag("全部")
                ForEach(SensorKind.allCases, id: \.self) { kind in Text(kind.rawValue).tag(kind.rawValue) }
            }.pickerStyle(.segmented)
            TextField("搜索名称、分组或键名", text: $model.sensorSearch).textFieldStyle(.roundedBorder)
            HStack {
                Text("传感器").frame(maxWidth: .infinity, alignment: .leading)
                Text("键名").frame(width: 72, alignment: .leading)
                Text("读数").frame(width: 90, alignment: .trailing)
            }.font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredSensors) { sensor in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sensor.name).font(.system(size: 13, weight: .medium))
                                Text("\(sensor.group) · \(sensor.controlEligible ? "参与温控" : "仅展示")").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(sensor.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary).frame(width: 72, alignment: .leading)
                            Text(String(format: sensor.kind == .temperature ? "%.1f %@" : "%.2f %@", sensor.value, sensor.kind.unit))
                                .font(.system(size: 13, weight: .medium)).monospacedDigit().frame(width: 90, alignment: .trailing)
                        }.padding(.vertical, 9)
                        Divider()
                    }
                    if model.filteredSensors.isEmpty { Text("当前筛选下暂无可读取的传感器").foregroundStyle(Palette.secondary).padding(.top, 40) }
                }.background(TransparentScrollBackground().frame(width: 0, height: 0).accessibilityHidden(true))
            }
        }.padding(24).frame(width: 600, height: 540).background(Palette.background)
    }
}

func rpmText(_ value: Double) -> String {
    Int(value.rounded()).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
}

struct PercentageSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let enabled: Bool
    @FocusState private var focused: Bool
    private var progress: Double { min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))) }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 14)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.accent.opacity(0.11)).frame(height: 4)
                Capsule().fill(Palette.indicator).opacity(0.7).frame(width: max(0, progress * width), height: 4)
                HStack(spacing: 0) {
                    ForEach(0..<31) { index in
                        Capsule().fill(Palette.secondary.opacity(0.35)).frame(width: 2, height: index % 5 == 0 ? 12 : 8)
                        if index < 30 { Spacer(minLength: 0) }
                    }
                }
                RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 14, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.accent.opacity(focused ? 0.6 : 0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1).offset(x: progress * width)
            }.frame(height: 28).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    guard enabled else { return }
                    focused = true
                    let fraction = min(1, max(0, (gesture.location.x - 7) / width))
                    value = min(range.upperBound, max(range.lowerBound, (range.lowerBound + fraction * (range.upperBound - range.lowerBound)).rounded()))
                })
                .focusable(enabled).focused($focused)
                .onMoveCommand { direction in
                    guard enabled else { return }
                    if direction == .left || direction == .down { value = max(range.lowerBound, value - 1) }
                    if direction == .right || direction == .up { value = min(range.upperBound, value + 1) }
                }
                .accessibilityElement().accessibilityLabel("自定义转速百分比").accessibilityValue("\(Int(value))%")
                .accessibilityAdjustableAction { direction in
                    guard enabled else { return }
                    value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? 1 : -1)))
                }.accessibilityIdentifier("speed-slider").opacity(enabled ? 1 : 0.45)
        }.frame(height: 28)
    }
}
