# QidianReader — Swift 原生起点阅读（登录 + 阅读 + 本地缓存）

只做三件事：**登录**、**阅读**、**把下载过的章节留在本地**。

把章节链接粘进窗口就能读。正文不会像浏览器那样竖向滚动，而是按窗口大小自动分页，**左右各一页**：

- 点击左侧：上一页
- 点击中间或右侧：下一页
- 本章最后一页再点下一页：自动进入下一章
- 本章第一页再点左侧：进入上一章，并落在最后一页

付费已购章节也能读——正文由官方 Fock 模块加密，客户端用离屏 `WKWebView` 复用官方解密。

读过的完整章节会按书名缓存到 `~/.qidian/<书名>/`；读完当前章后还会自动尝试缓存下一章。下一章如果没购买（只能拿到试读片段），直接忽略，不会落盘。

> 接口细节（含完整端点清单）：[docs/API.md](docs/API.md)

---

## 运行

```bash
swift run QidianReader
# 或 open Package.swift，在 Xcode 里跑 QidianReader scheme
```

窗口顶部粘贴章节链接 → 点“阅读”。未登录时右上角有“登录”按钮；登录后会自动重拉当前章（试读 → 全文）。

> 本项目只提供 macOS 图形客户端，不再包含命令行工具。构建/测试命令：

```bash
swift build --disable-sandbox
swift test --disable-sandbox
```

> 如果窗口没有出现在前台：先 `killall QidianReader`，再重新运行。应用启动时会把自己的激活策略设为普通 App 并主动抢焦点；早期构建没有这一步，窗口会创建但藏在后台。

---

## 分页阅读

正文用 CoreText 按当前窗口大小、字号、行距排版，再切成左右两页显示：

- 左侧 1/3 区域：上一页；在第一章第一页时继续点，会进入上一章并落在最后一页。
- 中间 1/3、右侧 1/3 区域：下一页；在本章最后一页继续点，会加载下一章。
- 调整窗口大小或字号/行距后会自动重新分页，并尽量停留在当前阅读位置。
- 页脚显示书名、当前页码和“下一页”提示；最后一页会提示下一章标题。

---

## 本地缓存与自动预取

缓存根目录默认是 `~/.qidian`，可用环境变量 `QIDIAN_CACHE` 覆盖：

```
~/.qidian/
├── cookies.json
└── 牧者密续/
    ├── _book.json          # bookId / 书名 / 作者
    ├── 753919666.json      # 每章一个 JSON：标题、正文段落、上下章
    └── 801714441.json
```

规则：

- **按书名建目录**。书名里的 `/`、`:` 等文件系统非法字符会替换成 `_`；同名不同书追加 `-<bookId>`，不会串书。
- **只缓存完整章节**。试读片段、空正文不落盘；下次会重新向服务端请求。
- **读完当前章自动预取下一章**。后台串行执行，不阻塞当前阅读；快速翻页时只保留最新的预取请求，不会整书往后爬。
- **下一章未购买则忽略**。接口返回试读时只记一个“已忽略”，不写文件，也不反复请求。
- 再次打开同一章时优先读本地缓存，不重复解密、不重复下载。
- 同一章的并发请求（用户翻页 + 自动预取）会合并成一个任务。
- 离屏 `WKWebView` 全局串行使用，避免预取和手动翻页同时 `load` 导致读到错误章节。

---

## 只保留了三个能力

| 能力 | 实现 |
|---|---|
| 登录 | `WKWebView` 打开真实登录页，轮询到 `ywkey` 后保存 Cookie |
| 阅读 | `getMChapterInfo` 取章节 + 正文；密文回退 `WKWebView` 解密；CoreText 分页为左右双页 |
| 本地缓存 | 完整章节按书名写入 `~/.qidian/<书名>/<chapterId>.json`；读完自动预取下一章，未购买则忽略 |

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
│   │   ├── ChapterCache.swift         # 按书名分目录的章节缓存
│   │   ├── QidianReadingSession.swift # 缓存优先 + 自动预取 + 密文回退 WebKit
│   │   └── WebChapterFetcher.swift    # 离屏 WKWebView + Fock（串行复用）
│   └── QidianReader/
│       ├── QidianReaderApp.swift      # 窗口、顶部栏、欢迎页
│       ├── PaginatedReaderView.swift  # 双页分页 + CoreText 排版
│       ├── ReaderStore.swift          # 阅读状态 / 登录态 / 主题
│       └── LoginSheet.swift           # 登录 sheet
├── Tests/QidianKitTests/              # 9 个单测
└── docs/
    └── API.md                      # 接口分析
```

---

## 阅读链路

```
粘贴链接
  → ChapterRef 解析出 bookId / chapterId
  → 查 ~/.qidian/<书名>/<chapterId>.json
       └─ 命中：直接分页渲染，并在后台预取下一章
  → 未命中：GET /webcommon/chapter/getMChapterInfo
       ├─ 免费章：<p> 明文 HTML → 段落
       └─ 已购章：Base64 密文 + fkp
              → 离屏 WKWebView 加载 /chapter/{bookId}/{chapterId}/
              → 官方 Fock 解密后读 span.content-text
  → 写入本地缓存（试读不写）
  → CoreText 按窗口大小分页 → SwiftUI 左右双页渲染
  → 后台尝试缓存下一章；下一章未购买则忽略
```

## 为什么付费章节要用 WebKit

`fkp` 解码后是 `window.onkeyfocus("…", version)`，正文由 `window.Fock`（Emscripten 混淆的 WASM）解密，依赖账号 id + 每章密钥池。硬移植成本高、改版即失效；离屏 WebView 直接复用官方逻辑，约 2 秒/章，还顺带兼容字体混淆。

---

## 隐私与不入库内容

以下内容已由 `.gitignore` 排除，不会被提交：

- `~/.qidian/cookies.json`（登录票据，等同密码）
- `~/.qidian/<书名>/`（缓存正文，可能受版权保护）
- `.build/`、`.chrome/`、崩溃日志 `*.ips`

仓库里只有源码、测试与接口分析文档。

## 已知限制

- 只支持 `m.qidian.com`；`www.qidian.com` 有腾讯 WAF（202 + JS 挑战）。
- 未订阅章节只能读到试读片段，这是服务端按账号权益返回的，客户端不绕过。
- 缓存命中后不再校验服务端；章节正文更新（例如作者修文）不会自动同步，删掉对应 JSON 即可重新下载。
- 接口与密钥方案可能变化；解析失败时先看 [docs/API.md](docs/API.md)。
- 仅用于个人账号本地阅读；正文版权归作者与阅文所有，请勿分发。
