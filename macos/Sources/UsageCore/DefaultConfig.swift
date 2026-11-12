// The compiled-in endpoint + estimation config. Values and their provenance are documented in
// RESEARCH.md (they are ported from lugia19/Claude-Usage-Extension @ d1ede81). Copy this JSON to
// ~/Library/Application Support/ClaudeUsageBar/endpoints.json to override it without rebuilding.
enum DefaultConfig {
    static let json = #"""
{
  "configVersion": 1,
  "baseURL": "https://claude.ai",
  "allowedHosts": ["claude.ai", "api.anthropic.com"],
  "endpoints": {
    "usage": "/api/organizations/{org}/usage",
    "credits": "/api/organizations/{org}/prepaid/credits",
    "bootstrap": "/api/bootstrap/{org}/app_start?statsig_hashing_algorithm=djb2",
    "accountProfile": "/api/account_profile",
    "organizations": "/api/organizations",
    "conversationList": "/api/organizations/{org}/chat_conversations?limit={limit}",
    "conversationTree": "/api/organizations/{org}/chat_conversations/{conv}?tree=true&rendering_mode=messages&render_all_tools=true",
    "projectStats": "/api/organizations/{org}/projects/{project}/kb/stats",
    "login": "/login",
    "anthropicCountTokens": "https://api.anthropic.com/v1/messages/count_tokens"
  },
  "cookies": { "session": "sessionKey", "org": "lastActiveOrg", "domain": "claude.ai" },
  "webTransportOriginPath": "/robots.txt",
  "tokens": {
    "systemPrompt": { "behavior": 28600, "tools": 58500, "skills": 5500, "trailing": 2300 },
    "preferencesSection": 2000,
    "featurePrompts": { "memory": 24800, "enabled_saffron_search": 3700, "inline_visuals": 4200 },
    "compactionSummary": 6000,
    "outputMultiplier": 4,
    "cachingMultiplier": 0,
    "cacheLifetimeMinutes": 60,
    "localEstimatorMultiplier": 1.4,
    "workspaceAttachmentMaxTokens": 25000,
    "imageTokensPerPixelDivisor": 750,
    "imageTokensMax": 1600,
    "documentTokensPerPage": 2250
  },
  "modelFamilies": ["Fable", "Opus", "Sonnet", "Haiku"],
  "modelWeights": {
    "claude-fable-5-1": 10,
    "claude-fable-5": 10,
    "claude-opus-5-5": 4,
    "claude-opus-5": 5,
    "claude-sonnet-5-5": 2,
    "claude-haiku-5-5": { "weight": 0.1, "longWeight": 0.5, "longAbove": 100000 },
    "claude-sonnet-5": 2,
    "claude-opus-4-8": 5,
    "claude-opus-4-7": 5,
    "claude-sonnet-4-6": 3,
    "claude-opus-4-6": 5,
    "claude-opus-4-5": 5,
    "claude-sonnet-4-5": 3,
    "claude-haiku-4-5": 1,
    "claude-3-opus": 15
  },
  "familyWeights": { "Fable": 10, "Opus": 5, "Sonnet": 3, "Haiku": 1 },
  "fallbackWeight": 5,
  "contextWindows": {
    "claude-fable-5-1": { "chat": 1000000, "workspace": [1000000, 967000] },
    "claude-fable-5": { "chat": 500000, "workspace": [1000000, 967000] },
    "claude-opus-5-5": { "chat": 1000000, "workspace": [1000000, 967000] },
    "claude-opus-5": { "chat": 1000000, "workspace": [1000000, 967000] },
    "claude-opus-4-8": { "chat": 500000, "workspace": [1000000, 967000] },
    "claude-opus-4-7": { "chat": 500000, "workspace": [1000000, 967000] },
    "claude-opus-4-6": { "chat": 500000, "workspace": [200000, 167000] },
    "claude-opus-4-5": { "chat": 200000, "workspace": [200000, 167000] },
    "claude-3-opus": { "chat": 200000, "workspace": [200000, 182904] },
    "claude-sonnet-5-5": { "chat": 1000000, "workspace": [500000, 467000] },
    "claude-sonnet-5": { "chat": 1000000, "workspace": [500000, 467000] },
    "claude-sonnet-4-6": { "chat": 500000, "workspace": [200000, 167000] },
    "claude-sonnet-4-5": { "chat": 200000, "workspace": [200000, 167000] },
    "claude-haiku-5-5": { "chat": 1000000, "workspace": [500000, 467000] },
    "claude-haiku-4-5": { "chat": 200000, "workspace": [200000, 167000] }
  },
  "estimatedCaps": {
    "claude_free":    { "session": 375000 },
    "claude_pro":     { "session": 3000000,  "weekly": 30000000,  "weekly:fable": 15000000 },
    "claude_team":    { "session": 3750000,  "weekly": 37500000,  "weekly:fable": 18750000 },
    "claude_max_5x":  { "session": 15000000, "weekly": 150000000, "weekly:fable": 75000000,  "weekly:sonnet": 90000000 },
    "claude_max_20x": { "session": 60000000, "weekly": 600000000, "weekly:fable": 300000000, "weekly:sonnet": 360000000 }
  },
  "peakHours": { "weekdaysOnly": true, "startHourUTC": 12, "endHourUTC": 18, "sessionCapDivisor": 1.5 },
  "windowKinds": {
    "session":       { "label": "Session (5h)", "hours": 5,   "capKey": "session" },
    "weekly_all":    { "label": "Weekly",       "hours": 168, "capKey": "weekly" },
    "weekly_scoped": { "label": "Weekly",       "hours": 168, "capKey": "weekly" }
  },
  "legacyWindowKeys": {
    "five_hour":        { "kind": "session" },
    "seven_day":        { "kind": "weekly_all" },
    "seven_day_sonnet": { "kind": "weekly_scoped", "model": "Sonnet" },
    "seven_day_opus":   { "kind": "weekly_scoped", "model": "Opus" }
  },
  "sandboxTools": ["prepare_session", "Bash", "Read", "Write", "Edit", "Glob", "Grep", "NotebookEdit"],
  "visualizeToolId": "6f616b42-0ed8-571e-823f-ee4aca6b7ce9:show_widget",
  "countTokensModel": "claude-opus-5",
  "scheduling": { "delayAfterResetSeconds": 60, "limitRetryMinutes": 30, "limitRetrySeconds": 120 }
}
"""#
}
