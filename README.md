# EdgeProfileDock

在 macOS 程序坞为 Microsoft Edge 和 Edge Beta 的不同资料创建头像启动器，点击运行中的头像即可切换到该资料已有的窗口。

[下载最新版](https://github.com/zhangzhangluzi/EdgeProfileDock/releases/latest) · [反馈问题](https://github.com/zhangzhangluzi/EdgeProfileDock/issues/new)

## 安装

需要采用 Apple 芯片的 Mac 和 macOS 14 或更新版本。Microsoft Edge 或 Edge Beta 需安装在系统「应用程序」目录（`/Applications`）。

1. 从 [Releases](https://github.com/zhangzhangluzi/EdgeProfileDock/releases) 下载对应版本的 `EdgeProfileDock-版本.zip`，解压并将 `EdgeProfileDock.app` 拖到「应用程序」。
2. 打开 EdgeProfileDock。发行包使用固定签名，尚未经过 Apple 公证。若 macOS 提示无法验证开发者，确认下载来源和校验值后，可按系统提示在「系统设置 → 隐私与安全性」选择「仍要打开」。[Apple 安装说明](https://support.apple.com/en-us/102445)
3. 如需校验下载文件，将同一发布页的 `SHA256SUMS` 放到 ZIP 旁边，在该目录运行 `shasum -a 256 -c SHA256SUMS`。

更新时，先从菜单栏退出 EdgeProfileDock，再用新版替换「应用程序」里的旧版。来自同一签名的升级可沿用辅助功能授权。首次安装或从不同签名来源切换时，在系统设置中为当前安装的应用授权。

## 创建和切换资料

1. 在管理窗选择 **Microsoft Edge** 或 **Microsoft Edge Beta**，点击「刷新资料」。
2. 勾选所需资料，点击「创建或更新所选图标」。快捷方式生成在 `~/Applications`，可用「打开文件夹」找到并拖到程序坞。
3. 开启「监听资料窗口」。若显示「辅助功能待授权」，点击「打开辅助功能设置…」，为 EdgeProfileDock 打开开关，回到应用点击「重新检查」。

图标优先使用 Edge 缓存在本机的头像，缺少头像时使用资料名称的首字。Edge Beta 的图标带有 β 标记。重新选中资料并保存即可更新头像。

开启监听后，有窗口的资料显示独立头像图标，Edge 原有的程序坞图标也会显示。点击运行中的头像会切回该资料已有的窗口。最后一个资料窗口关闭后，对应头像的运行进程退出。已固定到程序坞的头像会保留为快捷方式。

点击未运行的资料启动器时，Edge 会尝试打开对应资料。如果该资料没有窗口，Edge 可以创建窗口。如果已有窗口，Edge 也可能在其中打开一个新标签页。

## 菜单栏与后台监听

点击管理窗左上角的红色关闭按钮后，应用留在菜单栏并继续监听。点击菜单栏图标可重新打开管理窗、暂停监听或退出应用。

监听优先处理 Edge 启动、退出和窗口变化事件。窗口资料刚出现时有短间隔补查，正常运行时每 12 秒兜底检查一次。

## 排查常见问题

- **资料列表为空。** 先打开对应的 Edge 或 Edge Beta，确认至少有一个资料，再回工具点击「刷新资料」。
- **已授权，但工具显示待授权。** 在「系统设置 → 隐私与安全性 → 辅助功能」确认开关对应当前安装的 EdgeProfileDock。返回工具点击「重新检查」。如果刚更换过安装来源或签名，为当前版本重新授权一次。
- **资料图标没有进入运行状态。** 确认已创建对应启动器、「监听资料窗口」已开启，且该资料有一个普通浏览窗口。不同资料使用可区分的显示名称更容易匹配。
- **程序坞还显示旧头像。** 从程序坞移除旧图标，用「创建或更新所选图标」生成新版，再从 `~/Applications` 拖回程序坞。

## 本地数据与卸载

应用在本机读取 Edge 资料名称、账号、目录和缓存头像。辅助功能权限用于识别和切换 Edge 窗口。启动器清单保存在 `~/Library/Application Support/EdgeProfileDock/created_launchers.json`。

在「已创建启动器」中可以删除所选项，也可以从「管理」菜单清除全部。通过「更多 → 卸载 EdgeProfileDock…」可以选择保留现有启动器，或同时删除它们。保留的启动器仍可用来打开 Edge 资料。Edge 的资料和浏览数据会保留。

## 从源码构建

在 Apple 芯片 Mac 上安装 Xcode 或 Xcode 命令行工具后，在仓库根目录执行下面的构建命令。

```bash
./scripts/build.sh
```

脚本在临时目录编译和签名，结束时清理编译缓存。产物是 `build/EdgeProfileDock.app` 和 `build/EdgeProfileDock-版本.zip`。运行 `./scripts/smoke_test.sh` 可检查应用签名、内嵌启动器和本机 Edge 资料读取。

首次构建会下载并校验签名工具，生成本机固定签名。签名文件保存在 `~/Library/Application Support/EdgeProfileDock Signing/identity.p12`，口令由登录钥匙串保存。后续使用同一签名构建的版本可沿用本机授权。

构建脚本会校验已安装 EdgeProfileDock 的签名身份。如果这个 Mac 已安装 GitHub 发行包，而你需要用自己的本机签名构建，可以在另一台 Mac 上构建，或先将现有安装移出 `/Applications` 或 `~/Applications`，再使用构建产物并为它单独授权。也可以用 `EdgeProfileDock.xcodeproj` 开发调试。
