# sub2api 接口成本核查

核查时间：2026-09-15。官方仓库 `Wei-Shaw/sub2api`，固定 commit `881f3202694c6bc932446931a30c27d9675178b9`。本核查针对该源码，不代表已验证用户部署的版本。

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
   - `openAIProbeCacheTTL`（约 113 行）是 10 分钟。无 `force=true` 并不等于完全无上游请求；本应用另加独立的进程内每账号 10 分钟预算。
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

## 快照解析

`buildCodexUsageProgressFromExtra`（service 约 1486 行）定义：

| 数据 | Extra 字段 |
| --- | --- |
| 5 小时已用百分比 | `codex_5h_used_percent` |
| 7 天已用百分比 | `codex_7d_used_percent` |
| 绝对重置时间 | `codex_5h_reset_at` / `codex_7d_reset_at` |
| 相对重置秒数 | `codex_5h_reset_after_seconds` / `codex_7d_reset_after_seconds` |
| 样本时间 | `codex_usage_updated_at` |

本客户端不调用管理写接口，不修改 sub2api 的缓存或部署配置。详情/列表/测试连接仅在既定作用域下读取；主动额度读取可能引发服务端自己的上游探测及缓存更新。

## 官方源码位置

- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/handler/admin/account_handler.go`
- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/service/admin_account.go`
- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/service/account_usage_service.go`
- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/handler/admin/openai_oauth_handler.go`
- `https://github.com/Wei-Shaw/sub2api/blob/881f3202694c6bc932446931a30c27d9675178b9/backend/internal/handler/admin/usage_handler.go`
