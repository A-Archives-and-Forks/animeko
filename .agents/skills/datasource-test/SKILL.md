---
name: datasource-test
description: Test and debug an Animeko media source from its JSON config using the datasource-test-mcp HTTP MCP server. Validates selector config syntax offline, runs the real SelectorMediaSourceEngine pipeline (searchSubjects → selectSubjects → searchEpisodes → selectEpisodes → selectMedia) with per-step traces, iterates CSS selectors offline against saved HTML, tests matchVideo regexes, extracts real video URLs via CEF WebView, and probes actual playback with VLC. Use when asked to 测试数据源 / 调试 selector 配置 / verify a datasource JSON works / diagnose why a source finds no candidates for an episode or fails to play. Covers web-selector (CSS selector) sources in depth; other factories (rss/dmhy/mikan/jellyfin/...) via end-to-end testing. Also defines the capability-evolution (进化) loop: when a site is provably beyond current engine/WebVideoExtractor capabilities, write a capability-gap document and hand it to an isolated subagent that implements the new capability and outputs a git patch, then re-verify. Requires starting the MCP server from this repo (instructions inside).
---

# 用 JSON 配置测试 Animeko 数据源

给定一份数据源配置 JSON,按本 skill 的流程判定它:

- **L0 配置合法**: 字段/选择器/正则语法正确;
- **L1 解析层通**: 能为指定番剧的指定集数解析出候选播放页;
- **L2 视频层通**: 能从播放页解析出真实视频 URL;
- **L3 播放层通**: 视频 URL 真实可播放。

失败时要定位到**具体引擎步骤和配置字段**,给出修复,并复测。

失败还有一种**正当结局**: 网站形态太多,现有流程必然覆盖不了所有站点——站点可能超出
selector 引擎或 WebVideoExtractor 等组件的现有能力。此时不要硬调配置,走第 9 节的
「能力进化」流程: 取证 → 写缺口文档 → 交给隔离 subagent 实现新能力(输出 git patch) → 复测。

所有测试通过 `tools/datasource-test-mcp` 的 HTTP MCP server 完成。它直接调用 App 的
`SelectorMediaSourceEngine` 真实代码,行为与 App 一致。两份参考文档:

- `tools/datasource-test-mcp/README.md` — server 能力总览、多线路语义、运行方式;
- MCP 工具 `get_selector_engine_docs` — 每个引擎步骤的输入/输出/常见问题/最小配置示例
  (源文件 `tools/datasource-test-mcp/src/main/resources/selector-engine-docs.md`)。
  **开始调试 selector 源前先调用一次它**,里面的步骤语义本 skill 不再重复。

## 0. 启动并连接 MCP server

先探测是否已在运行(默认 `http://127.0.0.1:8264/mcp`):

```bash
curl -s http://127.0.0.1:8264/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
# 返回 {"jsonrpc":"2.0","id":1,"result":{}} 即在运行
```

没在运行则构建并后台启动:

```bash
./gradlew :tools:datasource-test-mcp:installDist
# unix / macOS:
tools/datasource-test-mcp/launcher &
# Windows (后台):
tools\datasource-test-mcp\build\install\datasource-test-mcp\bin\datasource-test-mcp.bat
```

调用工具的两种方式:

1. **MCP client 已配置**(工具名形如 `mcp__animeko-datasource-test__validate_selector_config`)——直接调用;
2. **直连 HTTP**(无需任何配置): server 是无状态 JSON-RPC,不需要 `initialize`,直接 POST `tools/call`:

```bash
curl -s http://127.0.0.1:8264/mcp -H 'Content-Type: application/json' -d '{
  "jsonrpc": "2.0", "id": 1, "method": "tools/call",
  "params": {"name": "validate_selector_config", "arguments": {"config": { ...配置JSON原样内嵌... }}}
}'
```

- 工具返回在 `result.content[0].text` 里,是一个 **JSON 字符串**,解析它得到结构化结果;
  `result.isError=true` 表示工具执行异常。
- `tools/list` 可枚举全部工具与参数 schema。
- server **串行**执行工具调用,不要并发多个请求。
- 长参数(整页 HTML)建议写入临时文件后用脚本拼 JSON-RPC body,避免 shell 转义问题。

## 1. 识别配置类型

先解析用户给的 JSON,按字段判定:

| 特征 | 类型 | 测试路径 |
|---|---|---|
| `factoryId == "web-selector"`(或含 `searchConfig`/`searchUrl`) | Selector (CSS) 源 | 本 skill 第 2–6 步全套 |
| `factoryId == "rss"` / `"dmhy"` / `"mikan"` / `"jellyfin"` / `"emby"` / `"ikaros"` 等 | 其他工厂 | 只走第 7 步 `test_subject_episode_source` |
| `{"mediaSources": [...]}` | 订阅列表 | 逐个取出按上两行处理(selector 工具默认只取第一个 web-selector 源) |

selector 工具的 `config` 参数接受四种形态(App 导出 / 裸 arguments / 裸 searchConfig / 订阅列表),
原样传入即可,无需手动拆包。

## 2. 离线校验配置(selector)

```
validate_selector_config(config)
```

- `issues[]` 按 `severity` 分 `error` / `warning` / `info`,每条带精确的字段路径;
- **有 error 必须先修**(选择器/正则/JsonPath 语法错误在真实运行中都是静默空结果,不修后面全白跑);
- warning 逐条判断: 如「searchUrl 不含 {keyword}」几乎总是配置错误;「没有 `(?<ep>)` 分组」会导致集数解析失败;
- 修改配置后**重新 validate** 再继续。

## 3. 用 Ani API 选一个测试条目

> ⚠️ 命名区分: `search_subjects`(下面这个,Ani API 元数据)与引擎步骤 `searchSubjects`
> (`selector_run_step` 的 step 值,请求目标站)只差一个下划线,是两回事。

1. 用户指定了番剧 → `search_subjects(query=番名)` 拿 `subjectId`;
   用户没指定 → `get_trends()` 挑一部热门当季番(目标站大概率收录;老站可再补一部完结老番);
2. `get_subject_episodes(subjectId)` 拿剧集列表,通常选第 1 集的 `episodeId`(整数);
3. 记下条目的中文名——后面单步调试时作为 `keyword` / `query.subjectName` 用。

Ani API 冷启动可能要 40s+(server 已设 90s 超时),首次调用慢是正常的,不要过早判死。

## 4. 解析层全流程(先关视频解析)

```
selector_resolve_episode(subjectId, episodeId, config, extractVideo=false)
```

`extractVideo=false` 只测解析层: 快、不启动 CEF/VLC、不弹窗。返回:

- `ok` + `summary`;
- `steps[]`: 每步 `{name, status: success|failed, summary, details, errors, durationMillis}`;
- `medias[]`: 找到的候选播放页(含线路、集数、playUrl)。

**从第一个 `status=failed` 的步骤开始排查**,对照下表行动:

| 最先失败的步骤 | 常见症状 (看 summary/details) | 下一步动作 |
|---|---|---|
| `aniMetadata` | Ani API 拿不到条目/剧集 | 检查 subjectId/episodeId 是否为有效整数;网络问题则重试一次 |
| `searchSubjects` | 404 | `searchUrl` 模板错误或站点换了搜索路径;先 `curl` 人工确认站点当前的搜索 URL 形态 |
| `searchSubjects` | `captchaKind` 非空 | **停**。本工具无法过验证码,报告用户改用 App 内设置页的数据源测试器 |
| `selectSubjects` | 解析出 0 个条目 | 转第 5 步: 拿搜索页 HTML 离线迭代 subjectFormat 的 selector;若 HTML 其实是 JSON,改用 `json-path-indexed` 格式 |
| `searchEpisodes` | 条目详情页 404 | 条目链接拼接错误,检查 `rawBaseUrl`(留空时从 searchUrl 推断,details 里能看到实际 URL) |
| `selectEpisodes` | 0 个剧集 / 0 条线路 | 转第 5 步: 拿详情页 HTML 离线迭代 channelFormat 的 selector |
| `selectEpisodes` | 剧集有了但 `episodeSort` 全空 | `matchEpisodeSortFromName` 正则没匹配上剧集名(需要 `(?<ep>)` 分组);对照 details 里的剧集名调正则 |
| `selectMedia` | `filteredCount=0` 但 original 非空 | 看 details 里的 `filteredOut`: 集数对不上(sort vs ep、电影/OVA 特判)或该条目根本不含目标集。也可临时把 config 的 `filterByEpisodeSort` 设 false 验证是过滤问题还是解析问题 |
| 全部成功但 `medias` 为空 | 目标条目排名靠后被截断 | 调大 `maxSubjectsPerName`(默认 3,App 内无此限制;条目按名称长度升序排) |

## 5. 单步调试与离线迭代

`selector_run_step` 参数速查(完整 schema 见 `tools/list`):

| step | 必需参数 | 说明 |
|---|---|---|
| `searchSubjects` | `config`, `keyword` | 真实请求搜索页,返回 HTML(默认 100k 截断,`maxHtmlLength` 可调) |
| `selectSubjects` | `config`, `url` 或 `html` | 解析条目列表;传 `html` 即离线 |
| `searchEpisodes` | `url` | 抓条目详情页,返回 HTML |
| `selectEpisodes` | `config`, `url` 或 `html`+`subjectUrl` | 解析线路/剧集;**离线传 html 必须带真实 `subjectUrl`**,相对链接以条目页所在目录为基,否则 playUrl 拼错 |
| `selectMedia` | `config`, `episodes`, `query` | `episodes` 直接用 selectEpisodes 输出的数组(`{channel?, name, episodeSort?, playUrl}`);`query` 为 `{subjectName, episodeSort, allSubjectNames?, episodeEp?, episodeName?}` |
| `matchWebVideo` | `config`, `url` | 离线测一个 URL 判为 视频/嵌套页/忽略 |
| `extractVideo` | `url`(可选 `config`) | 真实 CEF WebView 加载播放页拦截视频 URL |

**离线迭代 selector 的标准循环**(改选择器时用,避免反复打站点):

1. `searchSubjects` / `searchEpisodes` 抓一次 HTML(页面超过 100k 时调大 `maxHtmlLength`,截断的 HTML 解析会失真);
2. 人工读 HTML 找到目标元素的结构,修改 config 里的 selector;
3. `selectSubjects(html=...)` / `selectEpisodes(html=..., subjectUrl=...)` 离线验证,重复 2–3 直到解析正确;
4. 也可以不搬 HTML,直接传 `url` 让它现抓——但每次都是真实请求,**修改配置期间优先离线**;
5. selector 调好后回到第 4 步全流程复测。

## 6. 播放层: 视频 URL 解析与播放探测

解析层通过后:

1. **先离线调正则**: 从 `medias[0].playUrl` 猜/从站点播放页的网络请求里挑几个 URL,
   `matchWebVideo(config, url)` 确认判定(`matched` / `loadPage` / `continue`)。
   注意嵌套页判定优先于视频判定,`matchNestedUrl` 写太宽会把视频 URL 当页面加载导致永远超时;
2. **真实解析**: `selector_run_step(step=extractVideo, url=playUrl, config, probeResolvedVideo=true)`,
   或直接 `selector_resolve_episode(..., extractVideo=true, probeVideo=true)`(默认值)跑完整链路。
   会启动 CEF(首次初始化下载/解压较慢)与 VLC(可能弹播放窗口);`extractMode=all_channels` 可逐线路全测;
3. **单测最终 URL**: `probe_video(videoUrl, headers)` —— HTTP 探测 + VLC 真实播放几秒,报告分辨率/时长/编码。
   `headers` 用 extractVideo 返回的(含 Referer/User-Agent,防盗链站点必需);`showWindow=false` 可不弹窗。
   系统未装 VLC 时自动降级为仅 HTTP 探测,结论要相应弱化为「HTTP 可达」而非「可播放」。

WebView 拦不到视频 URL 时: 看 extractVideo 返回的 `diagnostics`(拦截到的请求样本),
从中找出真实视频 URL 的模式,回去改 `matchVideoUrl` / `matchNestedUrl`,先用 `matchWebVideo` 离线验证再重跑。
若 `diagnostics` 显示页面已正常加载却**完全没有媒体类请求**,用浏览器工具人工打开播放页对照——
如果需要点击播放器等交互后视频请求才出现,这不是配置问题,是 WebVideoExtractor 的能力缺口,转第 9 节。

## 7. App 级复核与非 selector 源

```
test_subject_episode_source(subjectId, episodeId,
    mediaSource={factoryId: "...", serializedArguments: {...arguments 对象...}})
```

- 对 **selector 源**: 它构造真实的 `SelectorMediaSource` 跑原生 `fetch()`(含限流、冷却重试、无条目数截断),
  是与 App 行为严格一致的最终复核——`selector_resolve_episode` 全绿后建议跑一次;
- 对 **rss/dmhy/mikan/jellyfin 等其他工厂**: 这是唯一的测试入口(selector_* 工具不适用);
  `serializedArguments` 传配置里的 `arguments` 对象;
- 默认 `candidateTestMode=all_channels` 逐个候选测试;
- SSL 握手类错误时结果里会附 `handshakeFailureDomainHint`(可能的换域名提示),报告给用户但**不要**自动改配置。

## 8. 判定标准与最终报告

结论必须分层陈述,不要混为一个"能用/不能用":

| 层 | 通过标准 |
|---|---|
| L0 配置 | `validate_selector_config` 无 error |
| L1 解析 | `selector_resolve_episode(extractVideo=false)` 的 `medias` 非空(找到目标集数的候选) |
| L2 视频 | `extractResults` 中至少一个候选 `resolvedVideo` 非空 |
| L3 播放 | 顶层 `ok=true`(至少一条线路通过播放探测;`first_success` 模式下即首条通过的线路) |

报告内容: 每层结果与证据(候选数、可用线路名、视频 URL、探测到的分辨率/时长);失败层的定位
(哪一步、哪个字段、site 端还是配置端);对配置做过的每一处修改;以及**修正后的完整配置 JSON**。
测试用的条目/集数也要写明(结论仅对被测集数成立)。

若判定为**能力缺口**(第 9 节),报告还需附: 进化需求文档路径、subagent 产出的 patch 路径、
应用 patch 后的复测结果。

## 9. 能力进化: 站点超出现有能力时

现有 selector 流程与 WebView 拦截覆盖不了所有网站。测试的正当结局除了「通过」与「配置修好了」,
还有第三种: **发现组件缺少某种能力**。此时按本节把缺口整理成文档,交给独立 subagent 实现新能力
(输出 git patch),主会话应用后复测——这就是「进化」: 在检测数据源的过程中发现自身能力的不足并改进。
可进化的不只是 selector 引擎,WebVideoExtractor、matchVideo 等组件同样适用。

### 9.1 先确认是能力缺口,不是配置没调对

宣布「做不到」之前,必须**同时满足**:

1. `validate_selector_config` 无 error;
2. 已按第 4–6 步离线迭代过(证明是 selector/正则**表达不了**,而不是没写对);
3. 拿到指向**机制性缺失**的证据(下表),必要时用你可用的浏览器工具人工访问站点复现对照。

典型缺口与确证方法(非穷尽,遇到新形态照同样思路取证):

| 组件 | 缺口示例 | 如何确证 |
|---|---|---|
| 引擎·搜索 | 搜索要用 POST / 需要动态 token / 需要登录态 | fetch 搜索 URL 拿到的不是结果页;浏览器 devtools 观察真实搜索请求的方法与参数 |
| 引擎·解析 | 条目/剧集列表由 JS 动态渲染,静态 HTML 无数据 | `searchSubjects`/`searchEpisodes` 返回的 HTML 里搜不到浏览器中肉眼可见的条目文本(引擎是无 JS 的 HTTP+静态解析) |
| 引擎·解析 | 搜索结果/剧集列表分页,目标在后面几页 | 首页 HTML 只含前 N 项加分页控件;引擎只取单页 |
| 引擎·selectMedia | playUrl 需要由 JS/接口计算,`<a>` 里没有 | HTML 里的 href 是 `javascript:...` 或占位符 |
| WebVideoExtractor | **需要用户手势(点一下播放器)才触发视频加载** | `extractVideo` 的 `diagnostics` 显示页面加载完成但没有任何媒体类请求;人工浏览器打开播放页,点击播放后 devtools 才出现 m3u8/mp4 请求 |
| WebVideoExtractor | 视频走 blob:/MSE/WebSocket,没有可拦截的 HTTP 媒体 URL | devtools Network 里只有 blob/WS,无媒体 HTTP 请求 |
| matchVideo | 判定需要看响应体/响应头,URL 层面区分不了视频与广告 | 两类 URL 结构相同,仅内容不同 |

### 9.2 写进化需求文档

路径: `docs/evolution/<yyyyMMdd>-<组件>-<短slug>.md`(目录不存在就创建)。固定结构:

```markdown
# 需要的新能力: <一句话>

- **组件**: SelectorMediaSourceEngine / WebViewVideoExtractor(注明平台) / matchVideo / ...
- **触发站点**: <URL>(最小复现配置与测试条目/集数见「复现材料」)
- **现象与证据**: <工具调用序列与关键输出摘录;人工浏览器复现的观察>
- **为什么现有能力做不到**: <落到具体代码与机制,例如「WebView 拦截器
  (AndroidWebMediaResolver.shouldInterceptRequest / DesktopWebMediaResolver 的
  onBeforeResourceLoad)只被动监听页面发出的请求,从不与页面交互,而该站点的
  播放器要在用户点击后才创建 video 元素并发起请求」>
- **新能力的行为定义**: <精确描述期望行为;建议的配置字段名、类型、默认值与 JSON 示例;
  默认值必须等价于旧行为>
- **兼容性约束**: 不改变现有源的行为;涉及 WebView 的能力需说明
  commonMain 接口与 androidMain/desktopMain/appleMain 三端实现
- **验收标准**: 用触发站点跑通第 4–6 步;`:app:shared:app-data:desktopTest`
  与 `:tools:datasource-test-mcp:test` 全绿
- **相关代码入口**: <文件清单>

## 复现材料
<最小配置 JSON、subjectId/episodeId、失败的工具调用参数与输出>
```

「为什么做不到」必须先**读过相关源码**、落到代码事实上,不要停留在现象描述——这一节的质量
直接决定 subagent 能否正确实现。

### 9.3 移交 subagent 实现,输出 git patch

进化实现**不在验证会话里做**——验证会话不修改 App 源码。启动一个独立 subagent
(Claude Code 用 Agent 工具、`general-purpose` 类型,建议 `isolation: worktree` 隔离工作区;
其他环境开新会话),prompt 必须自包含,要点:

```
读 docs/evolution/<文档名>.md,按其中「新能力的行为定义」在 animeko 仓库实现该能力。
1. 只依据该文档与仓库源码工作;不运行 MCP server,不做数据源验证(那是主会话的事);
2. 新配置字段的默认值必须保持旧行为;涉及 WebView 的能力要覆盖 commonMain 接口
   与 androidMain/desktopMain/appleMain 各端实现;
3. 为新逻辑补单元测试;跑 :app:shared:app-data:desktopTest 与
   :tools:datasource-test-mcp:test,确认全绿;
4. 不 commit、不 push;最后用 git diff 把全部改动输出为 patch,
   保存到 docs/evolution/<同名>.patch,报告 patch 路径与改动文件清单。
```

subagent 返回后由**主会话**闭环:

1. 审阅 patch: 改动范围是否与文档一致、默认行为是否确实不变、测试是否补了;
2. 应用 patch 到工作区,`./gradlew :tools:datasource-test-mcp:installDist` 重建并重启 server;
3. 用触发站点重跑第 4–6 步,确认新能力真的解决了问题;
4. 把复测结果回填进化文档的「验收标准」下,最终把**文档 + patch + 复测证据**一起交给用户,
   是否提交由用户决定。

## 10. 行为红线

- **验证码**(任何步骤返回 captchaKind)→ 立即停止该站点的重试,报告用户用 App 内测试器,不要换关键词硬试;
- **对目标站点保持克制**: 每次 searchSubjects/resolve_episode 都是真实请求。失败后先修配置或转离线,
  不要原样重跑;两次真实搜索之间自然间隔(配置里的 `requestInterval` 语义);
- **不要把整页 HTML 塞进对话上下文**: 只摘取与 selector 相关的片段;超大页面存临时文件处理;
- **不要自动改写用户的站点域名**(即使拿到 handshakeFailureDomainHint)——那只是提示,换域名由用户决定;
- 修改过配置就要从 validate 重新走,最终交付的配置必须是**完整重跑过第 4 步(建议含第 7 步)** 的版本;
- **能力缺口的判定必须满足 9.1 的三个前提**——「我没调出来」不是缺口,先穷尽配置手段并取证;
- **验证会话不直接修改 App 源码**: 进化改动一律由隔离的 subagent 产出 patch,
  主会话只负责审阅、应用、重建、复测。
