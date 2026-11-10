---
status: proposed
---

# iOS 应用是 core 之上的 SwiftUI 外壳，网页内容照旧

Godwit 的 iOS 应用是 `core` 之上的第三个外壳，地位和 `app/`（mygo 原生界面）一样：不 fork，不写第二个邮件引擎。`mobile/` 包由 gomobile 绑定成 `Godwit.xcframework`，在进程内创建 `core.Service`、启动本机 API（[0002](0002-single-owner-local-api.md)），并以 `full` 角色拨号自己的 socket；Swift 外壳通过它调用 `core.Service` 的方法，角色、审计、脱敏都原样生效。iOS 应用自身就是数据目录的**拥有者**。

主界面（账户与邮箱侧栏、统一列表、会话列表、视图、搜索、设置、审批卡片、账户设置与 OAuth）用 SwiftUI。撰写、Wit 页和阅读正文沿用 `web/` 的页面，在 WKWebView 里承载：macOS 上这些页面已经跑在 WKWebView 中，走 `window.webkit.messageHandlers.mygo`，iOS 的 WKWebView 支持同一机制，Swift 侧只需一个 `WKScriptMessageHandler` 把调用转给 Go（[0012](0012-native-shell-web-content.md) 的分工不变：**Go 端是内容的权威**）。

## 边界

- **Go 继续负责**：存储、同步、操作队列、发件箱、规则、标签、视图、审批与至多一次（[0004](0004-permission-gateway-taint.md)、[0006](0006-send-at-most-once.md)）、Wit 与 pi 运行时（[0024](0024-pi-moejs-agent-runtime.md)）、脱敏（[0025](0025-mask-at-cloud-egress.md)）、所有 HTTP。iOS 不改变任何一条信任边界。
- **Swift 只负责**：界面，以及只能在进程内拿到的系统能力——钥匙串（SecItem）、OAuth 的 `ASWebAuthenticationSession`、系统翻译、Foundation Models、后台刷新、App Intents。这些以 Go 接口的形式从 `Options` 注入（`Keyring`、`SystemTranslator`、`AppleIntelligence`），取代 macOS 上的辅助进程。
- **core 里不出现 iOS 专属逻辑**，只有注入点。`GOOS=ios` 同时满足 `darwin` 和 `unix` 标签，所以 macOS 专用的 `_darwin.go` / `_unix.go` 文件能为 iOS 编译；哪个文件运行时失败，就给它加 `!ios` 并配 `_ios.go` 桩。原型跑过的路径（启动、添加账户、同步、列表、搜索）一个也没遇到。
- **[0001](0001-pure-go-no-cgo.md) 的本意不变，但它的构建开关在 iOS 上不成立**：Godwit 自己的代码没有 `import "C"`，桌面构建仍是 `CGO_ENABLED=0`。在 `GOOS=ios` 下，purego（mygo 的 sqlite 插件和 Godwit 基于 dlopen 的桥接都用它）刻意拒绝 `CGO_ENABLED=0`（`purego/is_ios.go`），所以 iOS 构建用 `CGO_ENABLED=1`。它编译的 C 只有 purego 的运行时胶水和 gomobile 生成的绑定，都属于"平台桥接"，与 `native/` 下的 Swift 桥接同类。开启 cgo 后，`core`、`rpc`、`rpcbind` 为 iOS 构建不需要任何 `_ios.go` 桩。
- **文案与外观复用**：字符串来自 `internal/i18n` 的目录，由 Go 格式化、Swift 显示，不维护第二份字符串表；颜色与间距来自 `internal/theme`；术语遵循 `GLOSSARY.md`。

## Consequences

- `rpcbind` 对线外隐藏的方法（`SenderAvatar`、`GetMessageLazyImages`、`PluginReadme`、`InlineImages`、带进度的安装与下载、`FollowConversation`）隐藏的理由是**别的进程**不该拿到字节流、进度流或能试探密钥；iOS 应用自己就是拥有者，所以 `mobile/` 对这些方法直接绑定，不经 socket。
- core 只新增一处接缝，独立成 PR：`Options.Keyring`（钥匙串注入）。原型（开启 cgo）不需要任何 `_ios.go` 桩，也不需要 socket 路径选项：真机上 socket 是 `<容器>/Documents/godwit.sock`，98 字节，`sun_path` 上限 103，且容器路径形状固定。余量只有 5 字节，所以数据目录必须就是 `Documents` 本身，不能放进子目录。（模拟器的容器路径过长，开发构建在模拟器上改用 `/tmp` 下的短目录。）
- iOS v1 **不提供**：stdio 传输的 MCP 服务器（iOS 没有子进程；HTTP 传输照常）、原生插件（[0015](0015-native-plugins-trusted-subprocess.md) 的子进程模型以后可换成网络连接到 `godwit plugin-host`，协议不变）、`godwit mcp` / `godwit call`（iOS 上的对应物是 App Intents）、第三方脚本插件（App Store 2.5.2；以后评估 JavaScriptCore 宿主——0024 已把宿主层设计成可换）、推送中继。Skill（[0009](0009-skills-are-prompts-only.md)）和 HTTP MCP 可用。设置里相应入口在 iOS 上隐藏，不是禁用态。
- 后台同步受 iOS 约束：没有 IMAP IDLE，只有 `BGAppRefreshTask`（系统决定频率）和 `BGProcessingTask`（夜间索引）。推送需要中继服务器，v1 不做；如果做，只做"有变化"的空推送，不经手内容。
- SQLite 用 mygo sqlite 插件自己的库，以 `MygoSQLite.framework` 内嵌：插件只加载自己的构建（amalgamation 加 `plugins/sqlite/native/sqlite.c`，按 `mygo_sqlite_*` 符号校验），系统 `libsqlite3` 无法替代。mygo 目前不发布 iOS 版本；原型按 mygo 的编译选项（FTS5、R-tree）为 iphoneos 和模拟器构建了 SQLite 3.53.4，每个切片 1.3 MB。这些切片应当进 mygo 的发布，和桌面版放在一起。`mobile.Start` 把 `MYGO_SQLITE_LIBRARY` 指向内嵌框架（Go 在加载时就读取环境变量，早于 Swift 运行）。
- 标签作为 IMAP 关键字（[0035](0035-labels-as-imap-keywords.md)）让 Mac 与 iPhone 的状态经服务器收敛；Wit 对话存在 SQLite 行里（[0021](0021-conversations-in-sqlite-rows.md)），不跨设备，以后再议。
- 仓库新增 `mobile/`（Go，gomobile 绑定面）和 `ios/`（Xcode 工程）；CI 增加 macOS runner，签名复用 `.github/actions/macos-sign`；发布走 TestFlight / App Store。iOS 的 `ready-for-agent` issue 需要能构建 iOS 的代理。
- 多窗口（每封草稿一个撰写窗口）在 iOS 上是 sheet；快捷键只在 iPad 外接键盘下有意义。

## Considered Options

- **瘦客户端**：Mac 上跑 `--headless`，iOS 只是本机 API 的远程客户端。开发成本最低，所有扩展原样可用，但手机上没有数据、没有离线，Mac 不在线就没有邮件——违背本地优先和单一拥有者在手机上的含义。保留为开发期的调试方式（同一套 Swift 代码换传输即可），不作为产品形态。
- **把 mygo 扩展到 iOS**：mygo 的原生界面是自绘到 GPU 的桌面框架；iOS 的输入法、无障碍、手势和系统集成都要走 UIKit/SwiftUI，自绘得不偿失。
- **Flutter / React Native / 纯网页外壳**：多一套运行时，界面不原生，与 0012"主窗口原生"的取舍相反。
- **用 Swift 重写邮件引擎**：两份引擎、两份信任模型、两份同步语义；Swift 没有成熟的 IMAP 库。
- **在 iOS 上也用 moejs 跑第三方插件**：技术上可行（纯 Go），但 App Store 2.5.2 要求第三方代码在 WebKit / JavaScriptCore 中运行，且不得以商店式界面分发；先不做，内置的 pi bundle 不受影响（随二进制分发）。
