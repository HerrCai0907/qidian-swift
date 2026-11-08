# 起点阅读（m.qidian.com）接口逆向分析

> 目标：为 Swift 原生客户端提供可落地的接口说明。
> 分析时间：2026-11。接口随时可能变化，以下内容均来自真实抓包与线上验证。

---

## 1. 整体结构：三层

起点阅读不是「一个 REST API」，而是三层拼起来的：

```
┌──────────────────────────────────────────────────────────────┐
│ 1. SSR HTML                                                  │
│    /book/{bookId}/       书籍详情（pageData.bookInfo）        │
│    /soushu/{kw}.html     搜索结果（pageData.bookInfo.records）│
│    /chapter/{bid}/{cid}/ 章节首屏（pageData.chapterInfo）     │
├──────────────────────────────────────────────────────────────┤
│ 2. JSON 接口  /webcommon/*                                    │
│    mCategory          目录（分卷）                            │
│    getMChapterInfo    章节信息 + 正文                         │
│    review*            段评 / 章末评论                         │
│    getReadStatus ...  进度、书签、订阅、月票                   │
├──────────────────────────────────────────────────────────────┤
│ 3. 前端解密                                                   │
│    VIP 已购正文是 Base64 密文，由页面内 WASM 模块 "Fock" 解密 │
└──────────────────────────────────────────────────────────────┘
```

客户端最省事的组合是：**目录 / 章节 / 评论走 JSON，书籍详情与搜索走 SSR 解析，VIP 正文交给 WebKit 复用官方 Fock**。

---

## 2. 基础约定

| 项 | 值 |
|---|---|
| 主机 | `https://m.qidian.com`（移动站，无 WAF 挑战） |
| 桌面站 | `https://www.qidian.com`（腾讯 WAF，202 + JS 挑战，不建议直连） |
| UA | iPhone Safari，例如 `Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1` |
| 编码 | UTF-8 |
| JSON 信封 | `{"code":0,"data":…,"msg":"","serverTime":1794124555}` |
| 鉴权 | Cookie 会话 + `_csrfToken`（同时放 Cookie 和 query） |
| 分页 | 评论用 `page`；目录一次性返回全书 1373 章（约 180 KB） |

`code` 约定：`0` 成功；`404` 接口不存在；`-3` 参数错误；其它见 `msg`。

---

## 3. 登录态与 Cookie

登录走阅文通行证（`passport.yuewen.com` / `ptlogin.yuewen.com`），成功后 `.qidian.com` 下会有：

| Cookie | 作用 |
|---|---|
| `ywkey` | 会话票据（登录的核心凭证） |
| `ywopenid` | 用户标识（32 位） |
| `ywguid` | 用户/设备 GUID |
| `_csrfToken` | CSRF token，UUID 形式，必须回填到每个 `webcommon` 请求的 query |
| `fu` / `newstatisticUUID` | 统计与灰度，匿名也有 |
| `abPolicies` | A/B 实验分组 |
| `supportWebp` | 图片格式协商 |
| `w_tsfp` | 仅 PC 站 WAF 相关，移动站不需要 |

### 3.1 新会话必须先 bootstrap

全新会话直接调 `webcommon` 接口会 **403**。浏览器里的真实顺序是：

```
GET /book/{bookId}/            → 200，Set-Cookie: _csrfToken / fu / newstatisticUUID
GET /webcommon/book/mCategory  → 200
```

`GET /` 首页**不会**下发 `_csrfToken`，所以 bootstrap 必须是书籍页（或章节页）。
本项目在 `QidianClient` 里做了自动处理：没有 `_csrfToken` 且知道 `bookId` 时，先拉一次书籍页。

### 3.2 实测

```bash
# 1) 拿会话
curl -c jar.txt 'https://m.qidian.com/book/1037095853/' -H 'User-Agent: <iPhone UA>'
TOK=$(awk '$6=="_csrfToken"{print $7}' jar.txt | tail -1)

# 2) 调接口
curl -b jar.txt \
  "https://m.qidian.com/webcommon/chapter/getMChapterInfo?bookId=1037095853&chapterId=801714441&_csrfToken=$TOK" \
  -H 'User-Agent: <iPhone UA>' -H 'Referer: https://m.qidian.com/'
```

同一响应里可能连下 4 个 `_csrfToken`（服务端多副本下发）。浏览器 Cookie 罐里是“后写覆盖”，实际以最后一个为准；客户端按 last-wins 合并即可。

---

## 4. 接口清单

### 4.1 目录

```
GET /webcommon/book/mCategory?bookId={bookId}&_csrfToken={token}
```

响应（截断）：

```json
{
  "code": 0,
  "data": {
    "bookId": 1037095853,
    "bookName": "牧者密续",
    "chapterTotalCnt": 1373,
    "bookStatus": "完本",
    "limitFreeType": 3,
    "salesMode": 1,
    "vs": [
      {
        "vId": 109516838,
        "vN": "玻璃台阶",
        "cCnt": 69,
        "wC": 242664,
        "cs": [
          { "id": 753919666, "cN": "第一章 你是来逮捕我的吗", "cnt": 3659,
            "uT": "2023-05-21 07:33:10", "sS": 1, "uuid": 1 }
        ]
      }
    ]
  }
}
```

字段：

| 字段 | 含义 |
|---|---|
| `vs[].vN` / `vId` | 卷名 / 卷 id |
| `vs[].cs[]` | 章节列表 |
| `cs[].id` | chapterId |
| `cs[].cN` | 章节名 |
| `cs[].cnt` | 字数 |
| `cs[].uT` | 更新时间 |
| `cs[].sS` | 1=收费章节，0=免费 |
| `cs[].uuid` | 接口内部的章节序号；**实测不保证按目录顺序递增**（作者调整章节后仍保留原值），展示顺序一律以 `vs[].cs[]` 数组为准 |
| `limitFreeType` | 限免策略：1/2/3 对应不同的限免窗口 |

> 注意：`sS == 1` 不代表一定不可读。限免活动期间仍标 1，实际以章节接口的 `price` / `isBuy` 为准。

> 客户端实现：`QidianClient.catalog(bookId:)` 把响应解码成 `BookCatalog` / `CatalogVolume` / `CatalogChapter`；`QidianReadingSession.catalog(bookId:forceRefresh:)` 在进程内按 `bookId` 缓存整份目录，功能菜单「章节目录…」按卷展示并支持搜索、选章。

### 4.2 章节 + 正文

```
GET /webcommon/chapter/getMChapterInfo?bookId={bookId}&chapterId={chapterId}&_csrfToken={token}
```

响应结构：

```json
{
  "code": 0,
  "data": {
    "isLogin": 1,
    "bookInfo": { "bookId": 1037095853, "bookName": "牧者密续", "authorName": "不祈十弦", "…": "…" },
    "chapterInfo": {
      "chapterId": 801714441,
      "chapterName": "第三百五十七章 法之书的进化",
      "volumeId": 113704228,
      "wordsCount": 5178,
      "price": 25,
      "isBuy": 1,
      "vipStatus": 1,
      "cES": 0,
      "content": "jA1ImDUtFtd9x1Y+9hFK…（Base64 密文）",
      "fkp": "d2luZG93Lm9ua2V5Zm9jdXMoIi4uLiIsIDE2MzU3NTc0MjEp",
      "prev": 801550399,
      "next": 801810226,
      "extra": {
        "volumeName": "喰主之钥",
        "prevName": "第三百五十六章 大罪卡：狂猎之王",
        "nextName": "第三百五十八章 冬天司的诞生",
        "prevVipStatus": 1,
        "nextVipStatus": 1
      },
      "authorSay": "还没写完，今天字数会多一些！…",
      "randomFont": "",
      "fixedFontTtf": ""
    }
  }
}
```

`content` 的三种形态：

| 账号状态 | `content` | `isBuy` |
|---|---|---|
| 免费章节 | `<p>　　【正位召唤·狂猎】<p>　　…` 明文 HTML | 0 |
| 已购 VIP | 纯 Base64 密文（约 22 KB） | 1 |
| 未购 / 未登录 | 截断的试读 HTML，结尾带 `...` | 0 |

**关键结论：正文是否可见完全由服务端按账号权益决定，不是前端开关。** 同一 URL、同一接口，登录并订阅后才返回完整密文。

### 4.3 书籍详情（SSR）

```
GET /book/{bookId}/
```

HTML 中：

```html
<script id="vite-plugin-ssr_pageContext" type="application/json">
{"pageContext":{"pageProps":{"pageData":{"bookInfo":{…}}}}
</script>
```

`bookInfo` 主要字段：`bookId`、`bookName`、`authorName`、`desc`、`wordsCnt`、`bookStatus`、`chanName`、`subCateName`、`collect`、`recomAll`、`updChapterName`、`updTime`、`isVip`、`bookLabels`。

封面：`https://bookcover.yuewen.com/qdbimg/349573/{bookId}/180`。

### 4.4 搜索（SSR）

```
GET /soushu/{urlencoded(keyword)}.html
```

同样在 `pageData.bookInfo` 里：

```json
{
  "total": 1000,
  "isLast": 0,
  "records": [
    { "bid": 1037095853, "bName": "牧者密续", "bAuth": "不祈十弦",
      "cnt": "421.09万字", "cat": "轻小说", "subCateName": "原生幻想",
      "state": "完结", "favoriteCnt": "49.18万",
      "imgUrl": "//bookcover.yuewen.com/qdbimg/349573/1037095853/180" }
  ]
}
```

注意：关键词要手动做 URL 编码后拼字符串；用 `URL.appendingPathComponent` 会把 `%` 再编码成 `%25`，导致 404。

另有联想接口：`GET /webcommon/search/auto?kw={kw}&_csrfToken=`。

### 4.5 段评 / 章末评论

```
GET /webcommon/chapterreview/reviewsummary4m?bookId=&chapterId=&_csrfToken=
```

返回每个段落的评论数：`data.list[].paragraphId` + `textCount` + `reviewNum`，配合正文 `span.content-text[data-index]` 使用。

```
GET /webcommon/chapterreview/reviewlist4m?bookId=&chapterId=&paragraphId=&page=1&_csrfToken=
GET /webcommon/review/getchapterendcomments?bookId=&chapterId=&_csrfToken=
```

### 4.6 阅读进度 / 书签 / 订阅 / 月票

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/webcommon/chapter/getReadStatus` | 拉取阅读进度 |
| POST | `/webcommon/chapter/updReadStatus` | 上报进度（form-urlencoded） |
| GET | `/webcommon/book/mReadStatus?bookId=` | 书籍维度进度 |
| GET | `/webcommon/chapter/getBookMarkList?bookId=` | 书签列表 `data.markerList[]` |
| POST | `/webcommon/chapter/addBookMark` | 加书签 |
| POST | `/webcommon/chapter/delBookMark` | 删书签 |
| GET | `/webcommon/chapter/checkChapterMark` | 是否已加书签 |
| POST | `/webcommon/chapter/saveUserSetting` | 保存阅读设置（form） |
| POST | `/webcommon/bookshelf/addbooks?bookId=&_csrfToken=` | 加入书架 |
| POST | `/webcommon/subscription/mSubscribe?_csrfToken=` | 批量订阅 |
| GET | `/webcommon/subscription/mSubscribeAllInfo` | 订阅概览 |
| GET | `/webcommon/subscription/mSubscribeInfo` | 单章订阅信息 |
| GET | `/webcommon/ticket/getUserMonthTicket` | 月票状态 |
| POST | `/webcommon/ticket/voteMonthTicket` | 投月票 |
| GET | `/webcommon/ticket/getUserRecomTicket` | 推荐票状态 |
| POST | `/webcommon/ticket/voteRecomTicket` | 投推荐票 |

写操作一律需要登录态 + `_csrfToken`。

---

## 5. VIP 正文解密（最关键的一节）

### 5.1 密文与密钥池

已购章节返回：

- `content`：Base64 密文（5178 字的章节约 22.8 KB 字符串）
- `fkp`：Base64 的「密钥池脚本」

把 `fkp` 解码：

```js
window.onkeyfocus("xuVS1VCSkbWuK2NRFLKRHN0gnKMpS7Iu8pDg9oL6+…", 1635757421)
```

第二个参数是密钥版本/时间戳，第一个参数是加密后的内容密钥。

### 5.2 官方前端怎么解

从打包后的 JS（`chunk` 里的 `initFock` / `unlockFock`）可以还原：

```js
function initFock(userKey, fkp) {
  window.Fock.initialize();
  window.Fock.setupUserKey(userKey);   // userKey = 当前登录用户的数字 id
  if (fkp) eval(atob(fkp));            // 触发 window.onkeyfocus(key, version)
}

function unlockFock(contentBase64, chapterId) {
  return new Promise((resolve, reject) => {
    window.Fock.unlock(contentBase64, chapterId, (code, text) => {
      code === 0 ? resolve(text) : reject(new Error("F:e:u:" + code));
    });
  });
}
```

`window.Fock` 是 Emscripten 编译出的模块（wasm + asm.js 兜底），导出：

| 导出 | 作用 |
|---|---|
| `fock_i` | 初始化，设置 userKey |
| `fock_a` | 添加密钥池（`onkeyfocus` 内部调用） |
| `fock_u` | 解密正文 |
| `fock_s` | 签名 |
| `fock_e` | 编码 GUID（`YWQD` 字体混淆用） |

调用链：

```
onkeyfocus(keyBase64, version) → fock_a(key, len, version)
Fock.unlock(content, cid, cb)  → fock_u(content, len, cid, cb) → 明文 HTML
```

### 5.3 为什么不在 Swift 里重写

- 解密逻辑在 WASM 里，且经过 Emscripten 混淆；
- 依赖 `userKey`（账号 id）+ `fkp`（每章/每卷的密钥池）+ 版本号；
- 服务端随时可以换密钥方案，重写版本会立刻失效。

本项目采用的方案：**离屏 `WKWebView` + 注入 Cookie + 加载官方章节页 + 从 DOM 读取 `span.content-text`**。
实测 2 秒左右解出整章，且天然兼容字体混淆与后续改版。

> 如果一定要纯原生：可把 `window.Fock` 模块抽出来，用 JavaScriptCore（iOS/macOS 均支持 WASM）执行，再桥接回 Swift。工作量与维护成本都明显更高。

### 5.4 字体混淆（可能叠加）

页面里有 `YWQD` 模块，会动态注入 `@font-face`：

```
unicode-range: U+3400-4DB5;
```

并把部分字符包进 `<y…>` 标签 / 自定义 CSS 属性，配合 `fixedFontTtf`、`randomFont` 字段。
被混淆的字符直接从 DOM 复制会得到错字。本书第 357 章 `randomFont` 为空、无稀有区字符，未启用混淆。

---

## 6. 反爬体系

| 层 | 表现 | 应对 |
|---|---|---|
| 腾讯 WAF | `www.qidian.com` 返回 **202**，body 只有 `probe.js`（Chaos VM，约 95 KB），带 `X-WAF-UUID`、`x-waf-captcha-referer` | 不要直连 PC 站；用 `m.qidian.com` |
| 会话校验 | 新会话直接调接口 **403** | 先 GET 书籍页拿 `_csrfToken` |
| 验证码 | 页面加载 GEETest、腾讯 TCaptcha | 正常账号低频访问一般不会触发 |
| 字体混淆 | `YWQD` + 自定义 TTF | 用 WebKit 读渲染后的 DOM |
| 正文加密 | Fock WASM | WebKit 兜底 |
| 频率限制 | 未公开阈值 | 建议 ≥ 300 ms/请求，失败指数退避 |

本项目内置 350 ms 节流、403 自动 bootstrap 重试、202 直接报风控。

---

## 7. 映射到 Swift（登录 + 目录 + 阅读 + 缓存 + 进度）

| 能力 | Swift 类型 | 实现 |
|---|---|---|
| 目录 | `BookCatalog` / `CatalogVolume` / `CatalogChapter` | `QidianClient.catalog(bookId:)`；`QidianReadingSession.catalog(bookId:forceRefresh:)` 按书缓存 |
| 章节 | `ChapterData` / `ChapterInfo` | `QidianClient.chapter(bookId:chapterId:)` |
| 正文解析 | `ChapterHTMLParser` | `<p>` / `span.content-text` → `[String]` |
| 链接解析 | `ChapterRef` / `BookRef` | 章节支持 PC/移动站 URL 与 `bookId chapterId`；目录支持书籍页 URL 与纯 bookId |
| 会话 | `CookieJar` | `~/.qidian/cookies.json` |
| 本地缓存 | `ChapterCache` | 完整章节按书名写入 `~/.qidian/<书名>/<chapterId>.json` |
| 阅读进度 | `ReadingHistoryStore` | 每本书一条，写入 `~/.qidian/progress.json`；启动时恢复章节和正文锚点 |
| 付费解密 | `WebChapterFetcher` | 离屏 WKWebView + Fock（全局串行） |
| 编排 | `QidianReadingSession` | 缓存优先，密文回退 WebKit；读完自动预取下一章 |
| 登录 | `QidianReader.LoginSheet` | GUI 内 WKWebView 登录页 + 自动抓 Cookie |

自动预取只向后看一章：当前章拿到 `next` 后再请求一次；若返回 `isBuy == 0` 的试读片段，则按约定忽略，不写缓存、也不继续往后爬。因此不会对目录或整书产生批量请求。

MVP 客户端依赖 `getMChapterInfo` 和 `mCategory` 两个 JSON 接口；mCategory 每个进程内每本书只请求一次，除非用户手动刷新。搜索、书籍详情、评论、书签等端点保留在本文档中作为扩展参考。

## 8. 合规提示

- 起点/阅文用户协议禁止未经许可的抓取与再分发；本项目仅用于**个人账号的本地阅读**与接口学习。
- 不要绕过付费：解密只对**当前账号已购买**的章节生效，服务端按权益下发。
- 不要公开分发解密后的正文。
- 控制频率，避免影响线上服务与触发账号风控。
