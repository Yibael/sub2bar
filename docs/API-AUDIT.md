# sub2api 接口成本核查

核查时间：2026-09-16。官方仓库 `Wei-Shaw/sub2api`，固定 commit `881f3202694c6bc932446931a30c27d9675178b9`。本核查针对该源码，不代表已验证用户部署的版本。

## 普通 API 账号补充核查（2026-09-22）

本节核对官方 commit `1c0a69c0ceddb2fd21581c17ab09f6c500b89ba1`（2026-09-21），并更新客户端行为；未验证用户部署版本。以下规则优先于旧版文中“全部 Pin 都查询额度”的描述。

- `backend/internal/service/account_usage_service.go` 的 `getUsageForAccount`：普通 OpenAI / Anthropic API Key 即使配置了 sub2api 限额，仍不支持通用 `/accounts/:id/usage`。客户端仅将支持的账号送入额度批次、兼容单账号查询及额度冷却调度。能力按平台和类型判断：Anthropic OAuth / Setup Token；OpenAI / Antigravity / Grok OAuth；Gemini OAuth / API Key。不能通过查询失败推断没有配置限额。
- `backend/internal/handler/dto/mappers.go`：API Key / Bedrock 的 `quota_daily_limit/used`、`quota_weekly_limit/used`、`quota_limit/used` 随账号详情返回；仅启用的正数限额输出。服务端会将已过期日／周窗口的展示用量归零。客户端分别判断每一项，不将本地周限额当作上游七天额度，也不将总限额称为上游余额。
- 日／周重置优先遵循固定模式下服务端返回的 `quota_daily_reset_at` / `quota_weekly_reset_at`；滚动模式依据 `extra` 中的 `quota_daily_start` / `quota_weekly_start` 加 24 小时 / 7 天。只扩展读取这些非敏感时间字段的 allowlist，不保留 credentials。没有可靠时间不显示倒计时，总限额没有重置周期。到期显示等待更新，不在客户端虚构新窗口。
- 今日统计复用 `accounts/today-stats/batch`，新增解码 `cost`、`user_cost`、`requests` 和 `tokens`，不增加请求、不请求 Token 明细。`tokens` 是输入、输出、缓存写入及缓存读取 Token 的合计；卡片紧凑显示，悬停和详情保留完整整数。`standard_cost` 是标准价；`cost = SUM(COALESCE(account_stats_cost, total_cost) * COALESCE(account_rate_multiplier, 1))` 是账号费用；`user_cost = SUM(actual_cost)` 是用户扣费。依据 `repository/usage_log_repo_stats.go` 的 `GetAccountWindowStatsBatch`。金额和计数独立校验，不互相回退，缺失或非法值不冒充零；用户扣费仍来自服务端自然日、含全部用户，不套用订阅的 Admin 排除或统计时区。
- 普通 API 展示今日标准价用量、账号费用、请求数和 Token；用户扣费及各限额已用 / 上限在详情中，所有新增金额遵循隐私开关。没有月价或续费周期要求，不纳入现有 OAuth 订阅消费 / 成本汇总、今日实际消费汇总或周额度估算。
- 账号详情失败保留上次成功的卡片、限额和采样时间，以置灰表示非实时，并发不继续冒充实时值；没有历史快照则显示可展开的置灰占位卡片。详情成功且未配置限额才显示“未配置 sub2api 限额”；失败不能产生这一结论。已配置但已用金额缺失时保留条目、显示未知。
- 错误展示仅消费现有状态，不改变请求调度：Pin 数量旁的警告悬停按账号汇总详情、今日统计、上游额度、周期及今日实际消费错误，也保留账号状态和额度提醒；只纳入当前 Pin 和适用统计范围。移除全局错误横幅；单项统计失败不置灰整个账号，部分今日统计只标记缺失字段。置灰不禁用切换、展开或刷新；错误详情沿用客户端安全文案，不暴露响应正文。认证失败仍进入凭据恢复流程并暂停轮询。
- 额度区域与 OAuth 复用行样式而非逐条位置：只显示实际配置的日／周／总条目，高度随内容变化。未配置或无可用限额时，保留两行进度条的最小高度；今日用量保持左列。纯本地统计型 Pin 不进入上游额度计时，顶部显示状态刷新倒计时。
- 官方前端对应参考：`frontend/src/components/account/AccountUsageCell.vue` 的 `shouldFetchUsage`、API Key 今日统计、`quotaDailyBar` / `quotaWeeklyBar` / `quotaTotalBar`。部分国产平台、Ollama 等有专属套餐 / 余额接口，本次未新增这些适配器，不能宣称本地限额等同其上游额度。
- 切换只修改独立的选择状态，不等待、取消或追加请求；卡片和分页控件单独订阅该状态。请求仍异步执行，JSON 解码有非主线程回归测试。账号状态／额度批次各一次性提交完整快照，保留原有统计范围、旧值策略及计时；已有请求延迟不阻止选择新页，未知字段显示 loading。

## 当前客户端刷新策略

仅面板打开时调度三类请求，间隔从请求完成后计时，进行中的同类请求不重复调度：

| 设置 | 默认 / 可选间隔 | 请求及数据归属 |
| --- | --- | --- |
| 账号状态刷新间隔 | 默认 2 秒；2 / 5 / 10 / 15 / 30 秒 | 逐个查询已 Pin 账号详情，并批量查询 `accounts/today-stats/batch`；账号详情更新并发、上限和状态，今日统计使用 `standard_cost` |
| 额度与费用刷新间隔 | 默认 30 秒；5 / 10 / 15 / 30 / 60 / 120 秒 | `POST accounts/usage/batch`，只包含已读取的 Pin ID，`force: false`；百分比、重置时间、窗口费用和估算一起更新 |
| 今日与周期实际消费刷新间隔 | 默认 2 秒；2 / 5 / 10 / 15 / 30 / 60 / 120 秒；失败退避至最多 600 秒 | `GET usage/stats`，分别按今日及账号自己的周期、统计时区读取 `total_actual_cost`；不含 Admin 时共用一次 `users?role=admin` 查询，并分别查询相同范围的 Admin 小计 |

- 旧配置的额度间隔保持不变；新增账号状态间隔默认 2 秒。
- 账号目录独立于面板轮询：进入账号管理时检查内存缓存，首次或距上次成功完成已满 60 秒才发账号列表请求；缓存未过期不请求，手动刷新绕过期限，进行中的目录请求合并。后台刷新保留旧行，失败不更新成功时间；空列表也缓存。目录按当前连接隔离，服务器/密钥变更清空，代次检查阻止迟到响应串用。离开页面不持续轮询，不缓存到磁盘。
- 额度冷却按服务器 URL 与账号 ID 在进程内保存，从上一轮响应处理完成后计算；关闭面板只停止调度，不清除冷却。未到期重开沿用剩余倒计时，已到期重开只查询一次，不补发关闭期间错过的轮次。退出应用后不保留此计时。
- 关闭面板会取消正在进行的请求；取消完成前不启动下一轮额度请求，取消完成后仍等待一个配置间隔，因为服务端可能已收到请求。取消后的响应不会覆盖当前面板数据。多个分批或兼容单账号请求以整轮结束时间计时，避免提前重试。
- 自动刷新和取消后重新 Pin 不绕过额度冷却；自动批次仅包含已到期的 Pin 账号，新账号可立即查询。账号状态仍可在重开面板时立即查询。点击刷新按钮则立即对已读取的 Pin 账号执行一次普通额度查询，绕过客户端倒计时和失败退避；若尚无账号详情，先等待详情载入。已有额度请求时不重复发送、不排队补发。完成后从本次响应时间重新计算自动刷新期限；关闭面板、切换连接或取消轮询会清除待执行的手动刷新。
- 批量查询每批最多 100 个账号；旧服务端返回 404/405 时，同一连接会记住不支持批量，退回单账号查询：Anthropic OAuth/SetupToken 使用 `source=passive`，其他平台使用 `source=active`，都明确 `force=false`。
- 不再使用客户端固定 10 分钟预算。普通查询继续尊重服务端现有的上游探测逻辑；5 秒查询不保证 5 秒得到一次新的 OpenAI 样本。
- 失败保留完整旧快照并退避；账号状态退避上限 120 秒，额度逐账号退避上限 600 秒，单个失败不拖慢其他账号。重开面板和保存设置不会绕过已确定的失败重试时间。手动刷新只使用普通查询，不发送强制探测。
- 同一服务器与密钥下，保存刷新间隔保留统计、账号列表及 Pin；额度到期时间以最后完成时间加新间隔重新计算，而非从保存时重新计时。保存本身不发送请求，已到期任务由面板调度器执行。更换服务器或密钥才清空旧连接数据，并等待下次打开面板；冷却记录不携带密钥或快照数据，切回原服务器也不会绕过原账号冷却。
- 今日用量通过 `POST accounts/today-stats/batch` 独立查询，与账号详情并行，共用账号状态刷新周期，从两者完成后重新计时；仅传入已 Pin ID，每批最多 100 个。今日统计不等同于账号额度重置窗口统计，不触发或替代 `/usage` 请求，也不改变额度冷却。
- 今日用量只使用 `standard_cost`，表示服务端时区今日 00:00 起的标准价美元用量，不包含倍率，也不涵盖本实例未记录的请求。有效零值显示 `$0.00`；字段缺失、非法或请求失败时显示“—”和提示，不回退到 `cost` / `user_cost`，不将旧日金额继续当作今日统计。仅今日统计失败不会阻断账号状态更新，下个状态周期重试；401/403 会停止轮询。
- “本周计费”文案改为“本周用量”，仍使用原有 7 天额度窗口的 `cost`，保留账号倍率及账号统计成本调整，不改为标准价或自然周。
- 订阅消费独立于状态和额度调度；仅请求已 Pin、确认是 OAuth、价格和续费日完整的账号。含 Admin 为默认值。重开面板重新获取本地数据库统计，手动刷新按钮同时请求可用的订阅统计；已有任务时不重复发送。关闭面板、休眠、切换服务器/密钥、修改订阅或统计口径会取消旧任务，使用独立代次丢弃迟到结果。

## 已确认的调用链

1. `GET /api/v1/admin/accounts/:id`
   - `backend/internal/handler/admin/account_handler.go` 的 `GetByID`（约 927 行）→ `adminService.GetAccount`。
   - `backend/internal/service/admin_account.go` 的 `GetAccount`（约 55 行）只调用仓储 `GetByID`。
   - `buildAccountResponseWithRuntime`（handler 约 361 行）从并发服务读 Redis 计数；Anthropic 的窗口费用 / 会话 / RPM 使用本地统计及缓存。
   - 对 OpenAI 账号，这条路径不调用 `getOpenAIUsage` 或 OpenAI 探测接口。响应里的 `extra` 含已保存的 Codex 快照。
   - handler 另有 Ollama 专属 resolver；不能把本结论无限推广到任意第三方平台、自定义分支或将来版本。

2. `GET /api/v1/admin/accounts/:id/usage?source=active`
   - handler 的 `GetUsage`（约 2520 行）调用 `AccountUsageService.GetUsage`。
   - `backend/internal/service/account_usage_service.go` 的 `getOpenAIUsage`（约 711 行）先从账号 Extra 构造快照，但窗口缺失、限流或快照过期时仍可能调用上游。
   - 普通账号可通过 `probeOpenAICodexSnapshot` 请求 OpenAI Responses；Spark 影子账号可通过 `OpenAIQuotaService.QueryUsage` 请求上游额度。
   - `openAIProbeCacheTTL`（约 113 行）是 10 分钟，`shouldProbeOpenAICodexSnapshot` 在普通模式下检查该缓存，强制查询可绕过。它限制的是上游探测，不是客户端查询本地窗口统计的频率；本客户端不发送 `force=true`。
   - 同一返回还包含精确窗口的数据库费用统计，是原有周额度估算的依据。

3. `GET /api/v1/admin/accounts/:id/usage?source=passive`
   - `GetPassiveUsage` / `getPassiveUsageForAccount`（service 约 590 行）显式限制 Anthropic OAuth / SetupToken。
   - 从 Account.Extra 和本地统计构造结果，不调用外部 API。不能对 OpenAI 使用此参数冒充“只读缓存模式”。

4. `GET /api/v1/admin/openai/accounts/:id/quota`
   - `backend/internal/handler/admin/openai_oauth_handler.go` 的 `QueryQuota`（约 475 行）直接调用 `quotaService.QueryUsage`，不是缓存专用接口。本版不调用。

5. 其他统计接口不与账号额度窗口等价。
   - `accounts/:id/stats` 使用 `days` 参数及按天边界。
   - `usage/stats` 的 `start_date/end_date` 只接收 `YYYY-MM-DD`；`period=week` 是滚动 7 天，不是账号“7 天额度”的重置窗口。
   - 因此不能为了 5 秒更新费用而替换成这些口径不同的接口。

6. `POST /api/v1/admin/accounts/usage/batch`
   - handler 的 `GetBatchUsage` 将 `account_ids` 和 `force` 传给 service 的 `GetUsageBatch`（约 516 行）。
   - Anthropic OAuth/SetupToken 走 `getPassiveUsageForAccount`；其他平台复用主动查询逻辑，并传递 `force`。因此该 POST 是查询用途，但仍可能触发上游请求及服务端缓存更新。
   - 官方桌面账号页批量请求额度，前端有 5 分钟缓存；OpenAI 的刷新标识变化后会以 `force=true` 再查询。本客户端不照搬强制刷新行为。

7. 订阅周期实际消费（2026-09-17 补充核查，同一固定 commit）
   - `GET /api/v1/admin/usage/stats?account_id=...&start_date=YYYY-MM-DD&end_date=YYYY-MM-DD&timezone=...&nocache=true`：`UsageHandler.GetStats` → `UsageService.GetStatsWithFilters` → 使用日志统计仓储。使用 `total_actual_cost`，即用户实际扣费 `SUM(actual_cost)`，不使用 `total_cost` 或账号倍率口径 `cost`。
   - 接口按日期筛选，开始日期为本地配置的续费日，结束日期为请求发起日；时区总是显式传入。它不是上游额度窗口，也不调用 OpenAI。`nocache=true` 只绕过本地统计快照缓存，不触发上游探测。
   - 排除 Admin 时，先分页读取 `GET /api/v1/admin/users?role=admin`，仅解码用户 ID 和角色。不假设 Admin ID 为 1，不限制为活跃用户，不持久化用户目录。若返回角色不符、分页不完整或请求失败则停止本轮排除统计，不偷偷退回包含 Admin。
   - 每个账号先查询各 Admin 的 `user_id + account_id + 相同起止日期/时区` 小计，再查账号总计并相减。账号之间最多四个并发；无符合条件的账号不读取用户目录。若任何一个必要小计缺失或失败，该账号消费不可用；扣除后为负等口径异常也不伪装成零。
   - Admin 排除依据查询时的用户角色，不追溯请求发生时的历史角色。这些查询不是一个原子数据库快照，持续有请求写入时可能存在短暂的时间差；不是结算账单或精确到扣款时刻的对账系统。

## 本地订阅配置与汇总

- 顶部“今日实际消费”复用已核查的 `GET usage/stats`，将 `start_date` 与 `end_date` 均设为请求发起日在显式统计时区的 `YYYY-MM-DD`，读取 `total_actual_cost`。不使用今日标准价批量结果冒充实际扣费，也不调用上游。账号范围与周期汇总一致，仅包含已 Pin 且订阅配置完整的 OAuth 账号。
- 今日与周期使用同一个独立可配置的实际消费刷新间隔（默认 2 秒，2/5/10/15/30/60/120 秒），每轮复用一次完整 Admin 名单读取，各自查询相同日期条件下的 Admin 小计并相减，失败分别标记；任意账号今日统计不可用时不展示部分今日总额。续费当天两种日期范围相同，复用同一响应，避免重复查询。保存 Admin/时区/连接变更时清空不匹配样本，跨日后的迟到响应不会填入新一天，关闭面板取消全部统计任务。
- 账号状态/今日标准价、额度窗口/费用、今日与周期实际消费是三个独立调度通道。仅间隔或货币符号修改不取消请求、不清空样本，也不重置其他通道期限；对应通道完成后从完成时间使用新间隔，统计失败指数退避至最多 600 秒，缩短间隔不绕过已有失败等待。旧配置缺少实际消费间隔时默认 2 秒，但保留原账号状态和额度设置。实际消费不复用可能访问上游的 `accounts/:id/usage` 请求。
- 设置“账号管理”在账号目录中提供 Pin、OAuth 筛选和订阅编辑。月价数值与每月续费日按标准化服务器 URL + 账号 ID 保存到本地 `sub2bar.subscriptions.v1`，不向 sub2api 发管理写请求；取消 Pin 保留配置，清除订阅仅删除对应账号的本地元数据。
- “消费统计”中的实际消费和订阅成本货币符号独立配置，默认均为 `$`，最多 12 字符。数字固定保留两位小数，前面直接拼接填写的符号（如 `¥230.87`），不识别货币代码、不生成地区前缀、不加空格或做汇率换算。旧配置中常见代码迁移为符号（如 CNY/CN¥ → ¥、USD → $），保存后通过版本标记保持用户输入原样。订阅成本符号同步用于月价输入、账号列表及面板成本。今日用量、本周用量和周额度估算继续使用原有美元显示。仅符号变更时保留统计样本、进行中的请求及所有刷新期限，不发新请求。
- 月价允许显式 0；未填写价格或续费日不纳入消费与成本两侧汇总。不支持非 OAuth 账号配置。每个账号按各自周期计算，顶部订阅成本是这一组账号的完整月价之和，不按天摊销，不按自然月统一切割。
- 统计时区位于“消费统计”设置，初始采用当前 Mac 时区；随后随设置保存。边界为该时区续费日 00:00；短月取月末，下一月恢复原续费日（例如 1/31 → 2/28 → 3/31）。此为本地按日统计约定，不宣称是所有上游的扣款规则或时刻。
- 周期展示为首尾日期均包含：每月 15 日续费显示 `9 月 15 日 → 10 月 14 日`。内部仍使用 `[本次续费日零点, 下次续费日零点)` 半开区间，避免相邻周期重叠；接口的包含式 `end_date` 最多为下次续费日前一天，当前周期仍只查到今日。下次续费日当天归入新周期。
- 顶部不展示参与 Pin 数或 Admin 是否参与；缺少当前周期/当前 Admin 口径统计时仅显示“—”和“统计未完整”，而不是部分总消费。消费字段缺失/请求失败不会显示为零。价格/周期/统计时区/Admin 开关变更后不沿用不匹配样本；周期跨界后旧周期金额立即失效，待下一轮查询。
- 面板一次只创建当前选中的 Pin 账号卡片，支持左右按钮/方向键和折叠态横向拖动，故无需竖向滚动或测量全列表。展开详情按内容撑高，不再受旧 660 点上限限制；布局仅实际尺寸变化时更新 AppKit，不添加定时器或网络请求。周期、周期消费、订阅成本与今日用量采用同级紧凑指标，完整起止年份保留在提示和展开详情中。
- Pin 的持久化数组定义切换顺序；账号管理优先按此顺序显示已 Pin 行，通过上下按钮调整。移动位置不会取消轮询或清空统计，当前选中账号按 ID 保持不变；取消当前 Pin 选择邻近账号。面板只显示一页，但请求与顶部汇总范围仍为全部符合条件的 Pin 账号。非 Pin 不参与切换和汇总；缺失账号仍保留顺序位置并显示错误页。
- 今日实际消费与周期实际消费都是实际用户扣费，分别按配置时区的今日和各账号订阅周期汇总；账号卡片的今日用量仍为服务端自然日标准价，本周用量仍为上游 7 天额度窗口账号口径费用。原有周额度估算算法不变。

## 快照字段参考

### 今日统计（2026-09-17 补充核查，同一固定 commit）

- `AccountHandler.GetBatchTodayStats` → `AccountUsageService.GetTodayStatsBatch` → `usageLogRepository.GetAccountWindowStatsBatch`；SQL 批量查询失败时回退逐账号 `GetAccountWindowStats`，仍只查本地数据库，不调用 OpenAI 上游。
- 起点为 `timezone.Today()`；查询 `usage_logs` 的 `account_id` 与 `created_at >= 今日零点`。
- `standard_cost = SUM(total_cost)`；`cost = SUM(COALESCE(account_stats_cost, total_cost) * COALESCE(account_rate_multiplier, 1))`；`user_cost = SUM(actual_cost)`。
- handler 有批次快照缓存；客户端状态间隔不保证数据库样本每次都变化。服务端本身会把无记录账号映射为零，且该版本在批量与回退 SQL 都失败时也可能返回零；客户端无法从这种成功响应中区分数据库失败与真实零消耗。
- 今日接口不支持或报错时仅提示不可用，不回退至可能探测上游的额度接口。

`buildCodexUsageProgressFromExtra`（service 约 1486 行）定义：

| 数据 | Extra 字段 |
| --- | --- |
| 5 小时已用百分比 | `codex_5h_used_percent` |
| 7 天已用百分比 | `codex_7d_used_percent` |
| 绝对重置时间 | `codex_5h_reset_at` / `codex_7d_reset_at` |
| 相对重置秒数 | `codex_5h_reset_after_seconds` / `codex_7d_reset_after_seconds` |
| 样本时间 | `codex_usage_updated_at` |

以上是服务端账号详情中附带的快照字段。当前面板额度和费用以额度接口完整响应为准，不拿详情里的新百分比覆盖旧费用样本。本客户端不调用管理写接口、不直接修改缓存或部署配置；额度查询可能引发服务端自己的上游探测及缓存更新。

## 官方源码位置

- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/handler/admin/account_handler.go`
- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/service/admin_account.go`
- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/service/account_usage_service.go`
- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/handler/admin/openai_oauth_handler.go`
- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/handler/admin/usage_handler.go`
