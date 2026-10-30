# FanCool

原生 SwiftUI macOS 菜单栏风扇监测与控制工具，面向带风扇的 Apple M 系列 Mac。

当前版本：**1.8.7**。M2 Pro 上验证过直接控制；M3 Max 的兼容交接修改已收到实机测试通过的用户反馈。其他机型按硬件能力检测开放功能，尚未逐一验证；检测到风扇不代表已经验证该机型的全部调速行为。

## 功能

- 菜单栏动态风扇图标，左键打开控制面板，右键显示设置和退出。
- 分别显示每只风扇的实际 RPM、百分比、目标和控制状态。
- 系统、智能、手动三种模式；智能策略包含凉爽、均衡、静音。
- 手动提供低速、均衡、高速、全速和自定义；自定义支持分别控制风扇。
- 百分比按每只风扇各自的最大转速计算，最低值受固件限制。
- 展示明确映射的 CPU/GPU 控制温度、CPU 占用和传感器明细。
- 退出、失联、过温和后台重启时请求恢复系统控制，并记录恢复状态。

## 环境与构建

需要 macOS 13 或更新版本、Apple Silicon Mac，以及提供 Swift 编译器的 Xcode Command Line Tools。无风扇设备只能监测；未识别的 SMC 格式或不完整读数会阻止调速。

在项目根目录运行：

```sh
bash scripts/build.sh
open dist/FanCool.app
```

构建脚本生成：

- `dist/FanCool.app`：主程序、后台程序及图标资源。
- `dist/FanCool.zip`：完整 App 压缩包。

### 生成 DMG 安装包

```sh
# 构建最新 App 并生成只读、压缩的 DMG
bash scripts/package-dmg.sh

# 已经构建过且 App 内包含许可证时，可跳过重新构建
bash scripts/package-dmg.sh --skip-build
```

输出为 `dist/FanCool-<版本>.dmg` 和对应的 `.dmg.sha256` 校验文件。DMG 内包含 `FanCool.app` 和指向 `/Applications` 的快捷入口；打开后将 App 拖入“应用程序”，推出磁盘映像，再从“应用程序”启动。

DMG 打包会保留 App 原有签名，不自动进行 Developer ID 签名或 Apple 公证，也不会安装调速后台。后台仍由 App 设置页在本机单独授权安装。

默认采用本地 ad-hoc 签名，不需要付费开发者账号。构建脚本也支持通过 `CODE_SIGN_IDENTITY` 指定已有签名身份。当前没有接入固定私有签名、Developer ID 公证或免重复认证的后台更新机制。

本仓库提交源码及必要资源，不提交本地构建产物、调速日志、授权记录或签名私钥。DMG 安装包及校验文件见 [GitHub Releases](https://github.com/Crow0687/FanCool/releases)。

## 首次使用与权限

读取传感器无需管理员授权；调速需要安装本机 root 后台服务。在设置中点击“授权／更新授权”，由 macOS 系统弹窗完成管理员认证。FanCool 不接收或保存密码。

当前后台采用精确代码哈希验证，主程序或后台更新后需要重新绑定授权。授权不会随 ZIP 复制到其他 Mac；每台设备都需首次安装后台。无需辅助功能、屏幕录制或完全磁盘访问权限。

启动时，在授权、硬件及温度检查通过后，默认尝试启用已保存策略的智能模式。未授权、存在其他调速工具或恢复未完成时，保持系统管理。使用前应将其他调速工具切回系统自动并退出，避免同时控制。

## 控制与恢复

- 系统模式由 macOS 管理，FanCool 只监测；系统可能报告低于手动最低值的转速或 0 RPM。
- 智能模式根据可信控制温度计算目标，使用温度平滑、降速滞回和有限写入频率。
- 手动预设控制全部风扇；只有自定义模式展示单风扇范围和滑条，点击应用后生效。
- 智能控制的有效会话在原始控制温度达到 90°C 时请求全速；手动过温、严重热压力或无法完成控制交接时交回系统。
- 只有模式、目标与实际转速读回满足条件，才标记目标已确认。“调整中”表示等待确认；恢复未确认时保留记录并继续处理。

直接接管持续被固件拒绝时，只有识别到已支持的 `Ftst` 接口及完整风扇状态，才尝试有持久化恢复记录的兼容路径。1.8.7 采用最多 20 秒的分步交接，期间继续处理心跳和用户取消；恢复全部风扇时先退出全局兼容状态，再确认各风扇回到系统模式。不会停止 `thermalmonitord`。

这些温控曲线是实验性偏好，并非 Apple 官方阈值。模拟检查通过不等于已验证所有机型、固件或长期散热效果。

## 验证与诊断

```sh
# 核心检查：使用模拟硬件，不写入真实 SMC
swift run -c release FanCoolChecks

# 打包后的界面检查：使用演示硬件，不安装后台
dist/FanCool.app/Contents/MacOS/FanCool --ui-checks

# 只读硬件诊断与传感器枚举
dist/FanCool.app/Contents/MacOS/FanCool --diagnose
dist/FanCool.app/Contents/MacOS/FanCool --sensors

# 演示模式
open -n dist/FanCool.app --args --demo
```

1.8.7 构建通过 357 项核心检查及 57 项界面检查。自动检查包含延迟交接、取消、失联、超时、高温、双风扇回滚及恢复记录处理，不执行真实 SMC 写入。M2 Pro 已进行本机控制验证；M3 Max 于 2026-10-30 收到实机测试通过的用户反馈。

在设置中可以导出最近调速日志。日志包含写入及其结果、模式、目标、实际 RPM、`Ftst` 与热状态；它记录写入接受情况，不能仅凭 `completed` 判断风扇已达到目标。

## 项目结构

```text
Sources/FanCool/          SwiftUI 界面、菜单栏、后台客户端
Sources/FanCoolCore/      硬件编解码、温控策略、控制与恢复状态
Sources/FanCoolHelper/    特权后台、安装及恢复记录
Sources/SMCBridge/        AppleSMC C 接口封装
Checks/                  模拟硬件及故障检查
Resources/               App 信息与风扇素材
scripts/                 构建、打包和诊断脚本
```

产品名和源码模块为 FanCool。为兼容早期安装，运行时保留 `local.minifan.app`、`local.minifan.helper` 及 `/Library/Application Support/MiniFan` 等固定标识；它们不代表另一套后台服务。

## 参考与素材

- [Stats 的 SMC 实现](https://github.com/exelban/stats/blob/master/SMC/smc.swift)：模式键、转速编码及兼容接管行为参考。
- [Apple 代码身份校验](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。
- [Apple launchd 后台服务](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)。
- 风扇资源来源与生成记录见 [素材说明](Resources/fan-rotor-provenance.md)。

## 许可证

项目源代码和文档采用 [MIT 许可证](LICENSE)，版权署名为 Crow0687。允许使用、修改、商用及再分发，需保留版权和许可证声明。

第三方参考及声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。当前风扇图像及其衍生 App 图标暂不纳入 MIT 授权，原始参考图的权利仍待确认，详情见 [素材说明](Resources/fan-rotor-provenance.md)。
