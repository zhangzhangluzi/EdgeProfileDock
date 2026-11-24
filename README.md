# EdgeProfileDock

在 macOS 程序坞为 Microsoft Edge 和 Edge Beta 的不同资料创建头像启动器，点击运行中的头像即可切换到该资料已有的窗口。

[下载最新版](https://github.com/zhangzhangluzi/EdgeProfileDock/releases/latest) · [反馈问题](https://github.com/zhangzhangluzi/EdgeProfileDock/issues/new)

## 安装

需要采用 Apple 芯片的 Mac 和 macOS 14 或更新版本。Microsoft Edge 或 Edge Beta 需安装在系统「应用程序」目录（`/Applications`）。

1. 从 [Releases](https://github.com/zhangzhangluzi/EdgeProfileDock/releases) 下载 `EdgeProfileDock-版本.pkg` 和对应的 `.pkg.sha256`。在下载目录运行 `shasum -a 256 -c EdgeProfileDock-*.pkg.sha256` 校验。
2. 双击 `.pkg` 并按安装向导操作，应用会安装到「应用程序」文件夹。也可以下载 ZIP，解压后将应用拖入「应用程序」。
3. 发行版安装包尚未使用 Apple 开发者 ID 签名和公证。若 macOS 提示无法验证开发者，确认下载来源和校验值后，可按系统提示在「系统设置 → 隐私与安全性」选择「仍要打开」。[Apple 安装说明](https://support.apple.com/en-us/102445)

更新时，安装向导会要求先退出正在运行的 EdgeProfileDock，并检查已安装应用与安装包的签名是否一致。来自同一签名的升级可沿用辅助功能授权。首次安装或从不同签名来源切换时，在系统设置中为当前安装的应用授权。

## 创建和切换资料

1. 在管理窗选择 **Microsoft Edge** 或 **Microsoft Edge Beta**，点击「刷新资料」。
2. 勾选所需资料，点击「创建或更新所选图标」。快捷方式生成在 `~/Applications`，可用「打开文件夹」找到并拖到程序坞。
3. 开启「监听资料窗口」。若显示「辅助功能待授权」，点击「打开辅助功能设置…」，为 EdgeProfileDock 打开开关，回到应用点击「重新检查」。

图标优先使用 Edge 缓存在本机的头像，缺少头像时使用资料名称的首字。Edge Beta 的图标带有 β 标记。重新选中资料并保存即可更新头像。

同名资料会使用带浏览器和资料目录的不同文件名。已有启动器会沿用原路径，资料改名后也可以更新原来的图标。

开启监听后，有窗口的资料显示独立头像图标，Edge 原有的程序坞图标也会显示。点击运行中的头像会切回该资料已有的窗口。最后一个资料窗口关闭后，对应头像的运行进程退出。已固定到程序坞的头像会保留为快捷方式。

从 1.2.8 起，头像启动器优先切到对应资料的已有窗口。Edge 已运行且该资料没有窗口时，由 Edge 的「个人资料」菜单打开，开窗期间的连续点击会合并。Edge 退出时，头像启动器通过系统打开指定资料。

窗口资料暂时无法识别时，点击运行中的头像会提示刷新资料。窗口图标启动失败时会自动重试，重试仍失败会在管理窗和菜单栏显示状态。

升级后，在管理窗勾选原来的资料，再点一次「创建或更新所选图标」，以便为现有头像更新内核。Edge 已运行时，头像切窗和开窗需要 EdgeProfileDock 运行并获得辅助功能权限。

## 菜单栏与后台监听

点击管理窗左上角的红色关闭按钮后，应用留在菜单栏并继续监听。点击菜单栏图标可重新打开管理窗、暂停监听或退出应用。

勾选管理窗右上角的「登录时启动」，登录 macOS 后会自动在菜单栏启动。取消勾选可关闭自启动；若系统要求允许，请在「系统设置 → 通用 → 登录项与扩展」中启用。

监听优先处理 Edge 启动、退出和窗口变化事件。窗口资料刚出现时有短间隔补查，正常运行时每 12 秒兜底检查一次。

## 排查常见问题

- **资料列表为空。** 先打开对应的 Edge 或 Edge Beta，确认至少有一个资料，再回工具点击「刷新资料」。
- **已授权，但工具显示待授权。** 在「系统设置 → 隐私与安全性 → 辅助功能」确认开关对应当前安装的 EdgeProfileDock。返回工具点击「重新检查」。如果刚更换过安装来源或签名，为当前版本重新授权一次。
- **资料图标没有进入运行状态。** 确认已创建对应启动器、「监听资料窗口」已开启，且该资料有一个普通浏览窗口。不同资料使用可区分的显示名称更容易匹配。
- **程序坞还显示旧头像。** 从程序坞移除旧图标，用「创建或更新所选图标」生成新版，再从 `~/Applications` 拖回程序坞。

## 本地数据与卸载

应用在本机读取 Edge 资料名称、账号、目录和缓存头像。辅助功能权限用于识别和切换 Edge 窗口。启动器清单保存在 `~/Library/Application Support/EdgeProfileDock/created_launchers.json`。

在「已创建启动器」中可以删除所选项，也可以从「管理」菜单清除全部。通过「更多 → 卸载 EdgeProfileDock…」可以选择保留现有启动器，或同时删除它们。保留头像后，Edge 退出时可以按指定资料启动。Edge 已运行时，可通过浏览器自己的「个人资料」菜单切换。Edge 的资料和浏览数据会保留。

## 从源码构建

在 Apple 芯片 Mac 上安装 Xcode 或 Xcode 命令行工具后，在仓库根目录执行下面的构建命令。

```bash
./scripts/build.sh
```

脚本在临时目录编译和签名，结束时清理编译缓存。产物包括 `build/EdgeProfileDock.app`、ZIP、PKG 及 PKG 的校验文件。也可以运行 `./scripts/build_installer.sh`，为已构建的应用单独打包。运行 `./scripts/smoke_test.sh` 可检查应用签名、内嵌启动器和本机 Edge 资料读取。

运行 `./scripts/test.sh` 可检查同名资料、窗口资料别名、启动重试和安装签名。运行 `./scripts/test_installer.sh` 可检查安装包内容和升级时的签名保护。测试使用临时目录，结束后自动清理。

首次构建会下载并校验签名工具，生成本机固定签名。签名文件保存在 `~/Library/Application Support/EdgeProfileDock Signing/identity.p12`，口令由登录钥匙串保存。后续使用同一签名构建的版本可沿用本机授权。

构建脚本会校验已安装 EdgeProfileDock 的签名身份。如果这个 Mac 已安装 GitHub 发行包，而你需要用自己的本机签名构建，可以在另一台 Mac 上构建，或先将现有安装移出 `/Applications` 或 `~/Applications`，再使用构建产物并为它单独授权。也可以用 `EdgeProfileDock.xcodeproj` 开发调试。
