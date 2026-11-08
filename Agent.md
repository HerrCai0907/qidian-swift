# Agent.md

给在本仓库中工作的 Agent 的约束。

## 项目速览

- Swift Package（macOS 14+）：`QidianKit` 负责接口 / 解析 / 缓存 / 阅读进度，`QidianReader` 是 SwiftUI 分页阅读器。
- 入口文档：`README.md`；接口说明：`docs/API.md`。
- 本地数据在 `~/.qidian/`（Cookie、章节缓存、阅读进度），属于隐私内容，不要提交。

## 构建与测试

```bash
swift build --disable-sandbox
swift test --disable-sandbox
```

## 启动 App 必须带 `--no-activate`

开发、调试、自动化测试、截图、验证启动流程时，启动 App 一律加 `--no-activate`：

```bash
swift run --disable-sandbox QidianReader --no-activate
```

- 该 Flag 让 App 启动时不激活自己、不抢焦点、不把窗口提到最前；窗口照常创建并可用，但会排在当前前台 App 的窗口后面，不会打断正在使用电脑的人。
- **不要**不带 Flag 直接运行 `swift run QidianReader`：那会主动激活并把窗口弹到最上层，会打扰用户。
- 只有用户明确要求查看“启动后前台激活 / 窗口置顶”的效果时，才可以省略该 Flag。
- 在 Xcode 中运行同理：给 QidianReader scheme 的 Launch Arguments 加上 `--no-activate`。
- 受限环境（例如被外层沙箱包裹）里 `swift run` 不带 `--disable-sandbox` 会报 `sandbox-exec: sandbox_apply` 错误，按上面的完整命令执行即可。
- 启动的进程测试完要及时关闭：`killall QidianReader`，或结束自己启动的 PID，别把窗口留在后台。
- 需要观察界面时，请用户自己点 Dock 图标把窗口切到前台，或先征得用户同意再用默认方式启动。

## 其他约定

- 改动阅读链路（缓存、进度、分页、登录）后同步更新 `README.md` 与 `docs/API.md`。
- 提交前确认没有把 `cookies.json`、章节缓存、进度文件等本地数据带进仓库。
