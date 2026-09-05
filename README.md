# Auto Theme Switcher

Auto Theme Switcher 是一个仅常驻 macOS 菜单栏的本机工具。它读取 MacBook 的环境光传感器（ALS），在室外强光时把 VS Code 和 Ghostty 切换为亮色配置，回到室内后恢复现有暗色配置。

它不会修改 macOS 的浅色/深色外观，也不会调用 VS Code 或 Ghostty 的系统外观联动。

## 当前支持范围

- macOS 13 或更高版本，首要验证环境为 MacBook Air M4 / macOS 26.5.2。
- VS Code Stable 的默认用户配置。
- Ghostty 1.3 或更高版本。
- 本机直接分发，不面向 Mac App Store。

环境光读取使用公开 IOKit 查询函数，但依赖 Apple 驱动中未公开的 `CurrentLux` 属性。若系统升级后该属性消失，或驱动暂时返回 `UInt64.max` 等越界哨兵，App 会把本次读取视为失败并退避重试，保持当前主题且保留手动切换按钮；不会把无效值当成强光或 `0 lux`。

## 构建

当前机器的 `xcode-select` 指向 Command Line Tools，因此命令显式使用完整 Xcode：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
./Scripts/package_app.sh
```

打包完成后，应用位于：

```text
.build/app/Auto Theme Switcher.app
```

把它拖入 `/Applications` 后启动，才能稳定使用“登录时启动”。默认使用 ad-hoc 签名；如需 Developer ID 签名：

```bash
CODE_SIGN_IDENTITY="Developer ID Application: ..." ./Scripts/package_app.sh
```

## 首次启用

1. 启动 App，确认菜单栏能显示实时 lux。
2. 点击“安装或修复集成”。
3. 首次切换 Ghostty 时，macOS 会询问是否允许 Auto Theme Switcher 控制 Ghostty。该权限只用于检查 terminal 并执行 `reload_config`，不会读取或发送终端内容。
4. 有终端窗口时，App 通过 Ghostty AppleScript 对第一个 terminal 执行 `reload_config`。如果 Ghostty 进程仍在运行但没有终端窗口，App 会按 bundle id 精确定位已经完成启动且仍存活的 Ghostty 主进程，并向该 PID 发送 `SIGUSR2` 请求异步重载；`.reloadRequested` 只表示信号已成功送达，不代表重载已经完成。
5. Ghostty 未运行时不会启动它、创建窗口或改变焦点。若 Automation 权限被拒绝，App 不会改走 signal；配置文件仍会安全更新，请在 Ghostty 中手动按 `⌘⇧,` 重新加载。
6. “登录时启动”首次注册后若显示需要批准，请到“系统设置 → 通用 → 登录项与扩展”允许该 App。

首次集成会执行以下有限变更：

- VS Code：先创建逐字节备份和 ownership manifest，再把现有暗色 `workbench.colorCustomizations` 收进 `[Dark Modern]`，新增 `[Light Modern]`；以后每次只修改 `workbench.colorTheme`。
- Ghostty：在主配置末尾加入一个带固定标记的可选 `config-file`；自动切换只更新 App 自己的 mode 文件，不重复改写主配置。

任何 JSONC 语法错误、重复目标键、并发改动或哈希冲突都会让写入立即中止，不会用旧快照覆盖当前文件。

## 默认判断参数

- 进入室内：平滑光强持续低于或等于 `1000 lux`。
- 进入室外强光：平滑光强持续高于或等于 `5000 lux`。
- 平滑方式：最近 5 个有效样本的中位数。
- 稳定时间：5 秒。
- 切换后最短保持时间：15 秒。

两个阈值、稳定时间与最短驻留时间均可直接在菜单栏调整。必须满足：

```text
0 ≤ 室内阈值 < 室外阈值 ≤ 200000
```

手动点击“亮色”或“暗色”会同时暂停自动模式，避免传感器立即反向覆盖。再次选择当前模式时，即使配置文件无需改写，App 仍会尝试重载 Ghostty。

### 现场校准建议

先分别在常用室内位置和室外强光位置观察菜单栏中的“平滑光强”，再把室内阈值设在室内读数上方、室外阈值设在室外读数下方，并在两者之间保留足够的滞回区。不要把两个阈值设得过近；玻璃反射、屏幕亮度和手掌遮挡都会造成短时波动。调试时可以暂时缩短稳定时间，确认范围后再恢复为 5 秒或更长。

## 配置与备份

默认目标文件：

```text
~/Library/Application Support/Code/User/settings.json
~/Library/Application Support/com.mitchellh.ghostty/config.ghostty
```

App 自有状态和备份：

```text
~/Library/Application Support/dev.dtw.AutoThemeSwitcher/
```

VS Code 的 ownership 备份在集成生效期间保留；成功执行“恢复并停用”后会被安全消费并删除，以便以后重新安装。Ghostty 的亮色文件 `.auto-theme-switcher-light.ghostty` 首次生成后允许手工调整，App 日常切换不会覆盖它。

如果某个 VS Code Workspace 自己设置了 `workbench.colorTheme`，Workspace 配置优先于用户配置；v1 不会修改项目内的 `.vscode/settings.json`。

VS Code Insiders、自定义 Profile 和通过 `--user-data-dir` 启动的实例不在 v1 的自动路径发现范围内。App 只管理 Stable 默认 Profile 的用户配置，也无法从配置文件层可靠确认某个已打开窗口是否被 Workspace/Profile 覆盖；若文件切换成功但窗口外观未跟随，请检查该窗口的设置优先级。

事务日志只在一次跨应用写入尚未完整结束时存在。App 下次启动会按文件哈希尝试安全恢复；若文件在崩溃后又被外部编辑，恢复会停止并禁止后续自动写入，保留当前文件和日志供人工确认，而不会强行覆盖。

## 恢复与卸载

先在菜单栏点击“恢复并停用”。App 会：

1. 恢复暗色模式。
2. 对 VS Code 执行字段级逆迁移。
3. 删除 Ghostty 中完全匹配的管理标记和托管 mode 文件。
4. 关闭自动切换和登录启动。

如果相关托管区域已被外部修改，App 会保留文件并报告冲突，不会整文件恢复旧备份。用户改过的 Ghostty 亮色文件也会特意保留并在菜单中提示。

彻底卸载：

1. 先执行“恢复并停用”，确认没有冲突提示。
2. 如曾手工修改 Ghostty 亮色文件，确认内容不再需要后手工删除 `~/Library/Application Support/com.mitchellh.ghostty/.auto-theme-switcher-light.ghostty`。
3. 删除 `/Applications/Auto Theme Switcher.app`（或实际放置位置）。
4. 如需清理诊断/事务历史，再删除 `~/Library/Application Support/dev.dtw.AutoThemeSwitcher/`。

## 隐私与权限

- 不联网、无遥测。
- 不读取终端内容。
- 不需要 Accessibility、输入监控、摄像头或定位权限。
- 仅需要对当前用户的 VS Code/Ghostty 配置文件进行读写，并向 Ghostty 发送一次受 TCC 保护的 Apple Event：有终端窗口时执行 `reload_config`，无终端窗口时先通过该 Apple Event 确认 `no-terminal`，再在 Ghostty 仍运行时向其已完成启动且仍存活的主进程发送一次定向 `SIGUSR2`。该 signal 不会启动进程、创建窗口或改变焦点。

## 开发测试

如需在亮/暗切换后执行自定义逻辑，或接入其他程序的配置、CLI、AppleScript 和本地 API，请阅读[《扩展逻辑与外部程序控制》](docs/扩展逻辑与外部程序控制.md)。文档也说明了哪些能力可以参加跨应用回滚事务，哪些外部副作用应作为独立的切换后动作处理。

所有自动测试都使用临时配置目录，不接触真实用户配置：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
```

当前共有 65 项测试，覆盖光强滞回、无效驱动哨兵、睡眠唤醒预热、JSONC 保格式迁移、Ghostty include、Ghostty 有窗口与无窗口重载、SIGUSR2 异步请求、进程退出竞态、Automation 拒绝、亮暗双向信号路径、CAS 冲突、显式安装授权、跨应用事务回滚、磁盘事务日志、扩展属性保持和崩溃恢复。Ghostty 测试会在系统临时目录中调用已安装的 `+validate-config`，不会读写真实用户配置。
