# NiceDisplay

macOS 菜单栏外接显示器控制工具：**调节亮度 / 音量 / 分辨率，并键盘媒体键及F1 F2 F11 F12可以调节音量。
界面参考betterdisplay，纯小白 Workbuddy 手搓，仅自测，放出源码，供其他小伙伴参考。

A tiny macOS menu-bar utility for controlling external displays over DDC/CI — brightness, volume,
resolution/HiDPI, main-display switching — plus real support for the Magic Keyboard's
brightness keys on external monitors.

---

## 功能特性

- **亮度 / 音量调节**：走显示器 DDC/CI 通道，用妙控键盘 `F1/F2`（亮度）、`F10/F11/F12`（静音 / 音量）直接调，长按连续调节
- **亮度跟随鼠标所在屏**：鼠标在哪块屏，亮度键就调哪块（可在设置里关闭，改为只调主屏）
- **右上角长条 OSD**：仿系统原生样式的细长进度提示，只有进度条变化、不闪烁
- **每块显示器一行管理**：标题行 + 右侧开关（开 = 连接，关 = 熄屏断开）
- **分辨率 / HiDPI 一键切换**：勾选 HiDPI 自动选该屏支持的最高 HiDPI 分辨率，取消则回到最高普通分辨率
- **设为主屏幕、布局快照 / 一键还原、应急连回所有显示器**
- **内置命令行引擎 `dlite`**：所有功能都可通过 CLI 调用，方便脚本化
- 纯本地、无网络请求、无第三方依赖，只用一个 Swift/ObjC 原生 App + C 引擎

## 直接下载（不想自己编译）

预编译安装包就在这个仓库里：**[dist/NiceDisplay-1.0.dmg](dist/NiceDisplay-1.0.dmg)**

下载后打开 dmg，把 `NiceDisplay.app` 拖进「应用程序」即可。

> ⚠️ 本 App 使用 **ad-hoc 签名、未做 Apple 公证**。从浏览器下载后首次打开可能被 Gatekeeper 拦，
> 请 **右键点击 App → 打开**，或到 系统设置 → 隐私与安全性 点「仍要打开」。

## 系统要求

- macOS 13 或更高（在 macOS 26 上开发测试）
- 命令行工具（Xcode Command Line Tools）：`xcode-select --install`

## 编译

```bash
git clone https://github.com/yangc888999/NiceDisplay.git
cd NiceDisplay
bash build.sh
```

产物：

- `NiceDisplay.app` — 菜单栏应用（内含 `dlite` 引擎与图标）
- `NiceDisplay-1.0.dmg` — 分发包（含 app、安装说明、拖拽安装软链）

单独编译各部分：

```bash
# 引擎（CLI）
clang -O2 -o NiceDisplay.app/Contents/MacOS/dlite dlite.c \
      -framework CoreGraphics -framework IOKit -framework Foundation

# 菜单栏应用
clang -O2 -fobjc-arc -o NiceDisplay.app/Contents/MacOS/NiceDisplay DliteApp.m \
      -framework Cocoa -framework Carbon -framework CoreAudio \
      -framework CoreGraphics -framework ApplicationServices
```

## 安装与权限

1. 打开 dmg，把 `NiceDisplay.app` 拖进「应用程序」
2. 打开 App（菜单栏会出现显示器图标）
3. 首次启动会弹引导窗口，点「打开系统设置并授权」，在
   **隐私与安全性 → 辅助功能** 里勾选 NiceDisplay

> **macOS 不允许程序自行授权**，必须手动勾选（任何软件都一样）。
> 勾选后无需重启，程序 3 秒内会自动建立键盘监听；
> 若监听器被系统静默禁用，也会自动重新启用。

## 快捷键（苹果妙控键盘）

先确认 **系统设置 → 键盘 → 键盘快捷键… → 功能键** 里已勾选
**「将 F1、F2 等键用作标准功能键」**：

| 按键 | 功能 |
|---|---|
| `F1` / `F2` | 亮度 − / ＋ |
| `F10` | 静音 |
| `F11` / `F12` | 音量 − / ＋ |

> ⚠️ **重要**：若该开关关闭，`F1/F2` 会发出系统"亮度"媒体事件并被系统亮度服务提前消费，
> 第三方程序收不到（而且这类键盘的两个方向可能上报同一个编号，无法区分增/减）。
> 所以本工具要求把 F 键设为标准功能键，再从 HID 层直接接管标准键码。
> 改完若未生效，请把键盘电源关闭再打开（蓝牙键盘只在重连时重读该设置）。
>
> 副作用：该模式下 `F3`~`F9` 的 Mission Control / 播放控制需要按 `Fn+F3` 这类组合。
> 本工具也用 Carbon 全局热键注册了同样的无修饰键组合作为兜底，
> 因此即使辅助功能权限缺失，`F1/F2/F10~F12` 仍可用。

## 菜单里能做什么

- 每块显示器：标题行右侧开关 = 连接 / 熄屏断开（关闭后该屏配置收起，重开才展开）
- 亮度 / 音量滑块（拖动实时生效）
- 分辨率子菜单、高分辨率 (HiDPI) 一键切换
- 设为主屏幕（当前主屏带勾选标记）
- 设置窗口：常规 / 菜单显示项 / 高级（按键步长、配置文件、布局快照等）

## 命令行引擎 `dlite`

```bash
# 引擎位于 App 包内
DLITE="/Applications/NiceDisplay.app/Contents/MacOS/dlite"

$DLITE info                       # 列出所有显示器（id/uuid/主屏/活跃/DDC/分辨率/旋转）
$DLITE list                       # 简述列表
$DLITE ddc get  <id|uuid> 0x10    # 读 VCP（0x10 亮度 / 0x12 对比度 / 0x62 音量 / 0x8D 静音）
$DLITE ddc set  <id|uuid> 0x10 60 # 写 VCP（绝对值）
$DLITE ddc bump <id|uuid> 0x10 -5 # 相对增减
$DLITE mute     <id|uuid>         # 静音
$DLITE mode     <id|uuid> 1920x1080@60:hidpi   # 切换分辨率（可带刷新率与 HiDPI）
$DLITE presets  <id|uuid>         # 该屏的可用"标准分辨率"白名单
$DLITE hidpi    <id|uuid> on|off|toggle
$DLITE main     <id|uuid>         # 设为主屏
$DLITE arrange  <id|uuid> left|right|top|bottom   # 摆到主屏的指定方向
$DLITE disable  <id|uuid>         # 熄屏断开（会拒绝断开最后一块屏）
$DLITE enable   <id|uuid>
$DLITE restore                    # 连回所有显示器
$DLITE layout save|restore|show   # 布局快照
```

## 实现要点（供二次开发参考）

- **DDC/CI 通信**：通过 `IOAVServiceCreateWithService` + `IOAVServiceReadI2C/WriteI2C`
  私有接口读写显示器，VCP 事务字节序按 MCCS 规范
  （`0x51` / `0x80|len` / `0x03|vcp>>8` / `vcp&0xFF` / `值高字节` / `值低字节` / 校验和）
- **键盘接管**：`CGEventTapCreate` 挂在 **HID 层**（`kCGHIDEventTap`）而非 session 层，
  这样能在系统亮度服务消费之前拿到事件；同时监听标准功能键码与系统媒体事件
  （媒体编号 `0/1/7` = 音量增/减/静音）
- **回调必须立刻返回**：tap 回调里禁止建窗口 / 跑动画 / 做文件 I/O，
  所有 UI 一律 `dispatch_async` 到主线程，否则回调超时会被系统 `disable`，键盘监听整体失效
- **枚举显示器时**：`CGDisplayBounds` 原点在左下角；`CGDirectDisplayID` 会变化，持久化要认 UUID
- **ad-hoc 签名与 TCC**：每次替换二进制，macOS 视为新程序，辅助功能授权需重新勾选
  （这是系统机制，无法绕过）；本工具为此加了"授权后自动建监听器 + 定期健康自检"
- **旋转设置**：`CGSConfigureDisplayRotation` 等私有接口在 Apple Silicon 较新系统上未导出，
  本工具只能读取真实角度，旋转需到系统设置里手动调整

## 已知限制

- 华为 MateView 等部分显示器**不向 macOS 暴露系统音量**（系统音量滑块显示为缺失），
  音量完全由显示器内部决定，DDC 调到 0 仍可能偏响 —— 属该扬声器固件的最小增益
- DDC 回读偶发失败，因此程序区分"真值 0"与"读失败"，宁可跳过本次也不跳到错误亮度
- 亮度最低档受面板限制（柔光屏最低背光偏高），可降低对比度或使用
  macOS 辅助功能 → 显示 → 「降低白点值」进一步压暗

## 开发与自检

```bash
# 菜单结构 / 设置窗口 / 热键注册自检（打印结果后退出）
NiceDisplay.app/Contents/MacOS/NiceDisplay --selftest

# 端到端链路自检：合成媒体键事件 → 解析 → 动作 → DDC 写入 → 回读比对（含自动还原）
NiceDisplay.app/Contents/MacOS/NiceDisplay --mediatest
```

调试日志：`/tmp/nd_debug.log`（记录 tap 收到的事件、每次写入的目标值与显示器回读值）

## 许可

[MIT](LICENSE)
