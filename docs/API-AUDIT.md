# sub2api 接口成本核查

核查时间：2026-09-16。官方仓库 `Wei-Shaw/sub2api`，固定 commit `881f3202694c6bc932446931a30c27d9675178b9`。本核查针对该源码，不代表已验证用户部署的版本。

## 当前客户端刷新策略

仅面板打开时调度两类请求，间隔从请求完成后计时，同类请求不重叠：

| 设置 | 默认 / 可选间隔 | 请求及数据归属 |
| --- | --- | --- |
| 账号状态刷新间隔 | 默认 2 秒；2 / 5 / 10 / 15 / 30 秒 | 逐个查询已 Pin 账号详情；同一次响应一起更新并发、上限和状态 |
| 额度与费用刷新间隔 | 默认 30 秒；5 / 10 / 15 / 30 / 60 / 120 秒 | `POST accounts/usage/batch`，只包含已读取的 Pin ID，`force: false`；百分比、重置时间、窗口费用和估算一起更新 |

- 旧配置的额度间隔保持不变；新增账号状态间隔默认 2 秒。
- 额度冷却按服务器 URL 与账号 ID 在进程内保存，从上一轮响应处理完成后计算；关闭面板只停止调度，不清除冷却。未到期重开沿用剩余倒计时，已到期重开只查询一次，不补发关闭期间错过的轮次。退出应用后不保留此计时。
- 关闭面板会取消正在进行的请求；取消完成前不启动下一轮额度请求，取消完成后仍等待一个配置间隔，因为服务端可能已收到请求。取消后的响应不会覆盖当前面板数据。多个分批或兼容单账号请求以整轮结束时间计时，避免提前重试。
- 手动刷新和取消后重新 Pin 不绕过额度冷却；批次仅包含已到期的 Pin 账号，新账号可立即查询。账号状态仍可在重开面板时立即查询。
- 批量查询每批最多 100 个账号；旧服务端返回 404/405 时，同一连接会记住不支持批量，退回单账号查询：Anthropic OAuth/SetupToken 使用 `source=passive`，其他平台使用 `source=active`，都明确 `force=false`。
- 不再使用客户端固定 10 分钟预算。普通查询继续尊重服务端现有的上游探测逻辑；5 秒查询不保证 5 秒得到一次新的 OpenAI 样本。
- 失败保留完整旧快照并退避；账号状态退避上限 120 秒，额度逐账号退避上限 600 秒，单个失败不拖慢其他账号。重开面板和保存设置不会绕过已确定的失败重试时间。手动刷新只使用普通查询，不发送强制探测。
- 同一服务器与密钥下，保存刷新间隔保留统计、账号列表及 Pin；额度到期时间以最后完成时间加新间隔重新计算，而非从保存时重新计时。保存本身不发送请求，已到期任务由面板调度器执行。更换服务器或密钥才清空旧连接数据，并等待下次打开面板；冷却记录不携带密钥或快照数据，切回原服务器也不会绕过原账号冷却。
- 不额外请求 `today-stats/batch`，今日统计不等同于账号额度重置窗口统计。

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

## 快照字段参考

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
