# QidianReader — Swift 原生起点阅读（MVP）

只做两件事：**登录** + **阅读**。

把章节链接粘进窗口就能读，支持上下章、字号、行距、纸黄/纯白/夜间主题。付费已购章节也能读——正文由官方 Fock 模块加密，客户端用离屏 `WKWebView` 复用官方解密。

> 接口细节（含完整端点清单）：[docs/API.md](docs/API.md)

---

## 快速开始

```bash
swift build          # 本机沙箱环境用 --disable-sandbox
```

### 登录

```bash
.build/debug/qidian login
```

弹出起点登录页，登录成功后自动把 Cookie 存到 `~/.qidian/cookies.json`。

### 阅读

```bash
# 直接粘链接
.build/debug/qidian read https://www.qidian.com/chapter/1037095853/801714441/

# 或者 bookId + chapterId
.build/debug/qidian read 1037095853 801714441

# 免费章节不登录也能读
.build/debug/qidian read 1037095853 753919666
```

### 图形客户端

```bash
swift run QidianReader
# 或 open Package.swift，在 Xcode 里跑 QidianReader scheme
```

窗口顶部粘贴章节链接 → 点“阅读”。未登录时右上角有“登录”按钮；登录后会自动重拉当前章（试读 → 全文）。

> 如果窗口没有出现在前台：先 `killall QidianReader`，再重新运行。应用启动时会把自己的激活策略设为普通 App 并主动抢焦点；早期构建没有这一步，窗口会创建但藏在后台。

---

## 只保留了两个能力

| 能力 | 实现 |
|---|---|
| 登录 | `WKWebView` 打开真实登录页，轮询到 `ywkey` 后保存 Cookie |
| 阅读 | `getMChapterInfo` 取章节 + 正文；密文回退 `WKWebView` 解密 |

刻意没做：搜索、书籍详情、目录、书架、评论、月票、阅读进度同步。

---

## 工程结构

```
QidianKit/
├── Package.swift
├── Sources/
│   ├── QidianKit/
│   │   ├── Models.swift               # ChapterData / ChapterInfo / ChapterRef
│   │   ├── QidianClient.swift         # 章节接口 + Cookie + 403 bootstrap
│   │   ├── CookieJar.swift            # Cookie 持久化 / CSRF
│   │   ├── HTMLParser.swift           # 正文 HTML → 段落
│   │   ├── QidianReadingSession.swift # API 优先，密文回退 WebKit
│   │   ├── WebChapterFetcher.swift    # 离屏 WKWebView + Fock
│   │   └── LoginWindow.swift          # 登录窗口
│   ├── qidian/                        # CLI：login / read
│   └── QidianReader/                  # SwiftUI macOS 客户端
├── Tests/QidianKitTests/              # 6 个单测
└── docs/
    └── API.md                      # 接口分析
```

---

## 阅读链路

```
粘贴链接
  → ChapterRef 解析出 bookId / chapterId
  → GET /webcommon/chapter/getMChapterInfo
       ├─ 免费章：<p> 明文 HTML → 段落
       └─ 已购章：Base64 密文 + fkp
              → 离屏 WKWebView 加载 /chapter/{bookId}/{chapterId}/
              → 官方 Fock 解密后读 span.content-text
  → SwiftUI 渲染
```

## 为什么付费章节要用 WebKit

`fkp` 解码后是 `window.onkeyfocus("…", version)`，正文由 `window.Fock`（Emscripten 混淆的 WASM）解密，依赖账号 id + 每章密钥池。硬移植成本高、改版即失效；离屏 WebView 直接复用官方逻辑，约 2 秒/章，还顺带兼容字体混淆。

---

## 隐私与不入库内容

以下内容已由 `.gitignore` 排除，不会被提交：

- `~/.qidian/cookies.json`（登录票据，等同密码）
- `.build/`、`.chrome/`、崩溃日志 `*.ips`

仓库里只有源码、测试与接口分析文档。

## 已知限制

- 只支持 `m.qidian.com`；`www.qidian.com` 有腾讯 WAF（202 + JS 挑战）。
- 未订阅章节只能读到试读片段，这是服务端按账号权益返回的，客户端不绕过。
- 接口与密钥方案可能变化；解析失败时先看 [docs/API.md](docs/API.md)。
- 仅用于个人账号本地阅读；正文版权归作者与阅文所有，请勿分发。
