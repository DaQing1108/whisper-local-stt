# Claude Code Handoff: Whisper UI Static Redesign Phase 1

Date: 2026-07-02
Project: `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper`
Repo: `https://github.com/DaQing1108/whisper-local-stt.git`
Branch: `main`
Base commit: `df3d4fd`
Target: `Whisper STT macOS app main UI`

## BLUF

Codex 已完成 Whisper 主畫面的設計收斂、macOS layout spec、最終方向決策與 implementation plan。Claude Code 的任務不是重新設計，而是依照既定文件，完成 **Phase 1 靜態改版**：重組主畫面結構與樣式，使 UI 朝 `版本 3 為主視覺 / 版本 2 為品牌語言 / 版本 1 為 layout discipline` 的方向落地。這一輪應只聚焦在 `templates/index.html`、`static/app.css`、`static/app.js` 的最少量配合，不應擴大到後端邏輯、整合流程、Preferences 重構或 release 流程。

## Current State

- 已存在三份決策文件，足以作為唯一 source of truth：
  - `docs/Whisper_macOS_UI_Layout_Spec_v1.md`
  - `docs/Whisper_UI_Final_Direction_Decision_v1.md`
  - `docs/Whisper_UI_Implementation_Plan_v1.md`
- 使用者已同意：
  - 選用 `版本 3` 為主設計方向
  - 使用 `版本 2` 作品牌語言補強
  - 使用 `版本 1` 作版面紀律
- 此次 scope 已明確限定為 `靜態改版`
- repo 目前有其他 dirty / untracked 檔案，請保留，不要整理或清掉

## Acceptance Criteria Source

- Source: `docs/Whisper_UI_Final_Direction_Decision_v1.md` + `docs/Whisper_UI_Implementation_Plan_v1.md` + Alex 在本對話中對「靜態改版」與「哪些檔案可直接改」的確認
- Status: Locked
- Rule: Claude Code should pause and ask Alex before accepting any AC that expands beyond Phase 1 static redesign.

## Acceptance Criteria

- Locked AC:
  - AC-1: 主畫面 DOM 結構收斂為五段式：`toolbar`、`capture panel`、`context bar`、`results workspace`、`action bar`
  - AC-2: 主畫面第一視覺焦點改為中央錄音主區，而不是分散式 header 或大型說明卡
  - AC-3: transcript 區與底部 actions 在視覺上整合為同一個 workspace
  - AC-4: 系統音訊提示由大型常駐卡片收斂為較 slim 的 guidance strip 風格
  - AC-5: `Notion` / `Obsidian` 的主畫面呈現朝輸出狀態導向收斂，不再是分散式頂部 toggle 視覺
  - AC-6: 本輪僅允許最少量 `static/app.js` 配合，不能重寫核心狀態機、錄音流程、後端 API 或整合邏輯
  - AC-7: 保持現有功能可接線，不得為了靜態改版而破壞主流程
- Extra suggested checks, not mandatory AC:
  - 在窄視窗下做一次基本排版檢查，避免 toolbar 與 action row 明顯重疊
  - 若容易做到，可順手讓空狀態文案更像正式產品
- Unauthorized AC:
  - 任何 Preferences 大改
  - 任何 Notion / Obsidian 實際同步流程重寫
  - 任何錄音、轉寫、上傳邏輯重構
  - 任何打包、簽章、release、自動更新處理

## Files Changed By This Work

```text
templates/index.html
static/app.css
static/app.js
```

Allowed only if truly necessary and still in scope:

```text
tests/e2e/test_ui.py
tests/manual_checklist.md
```

Do not touch in this handoff unless Alex explicitly reopens scope:

```text
templates/preferences.html
static/preferences.css
static/preferences.js
app.py
routes.py
integrations.py
system_audio.py
transcribe.py
whisper_core.py
```

## Verification Already Run By Codex

```bash
git status --short
git branch --show-current
git rev-parse --short HEAD
git remote -v
rg --files templates static | sort
```

Result:

```text
Repo branch: main
Base commit: df3d4fd
Remote: origin https://github.com/DaQing1108/whisper-local-stt.git
Relevant frontend files confirmed:
- templates/index.html
- static/app.css
- static/app.js
- templates/preferences.html
- static/preferences.css
- static/preferences.js
Dirty/untracked files exist and should be preserved.
```

Known caveats:

- 工作樹目前不是乾淨的，包含：
  - modified: `.claude/settings.json`, `static/preferences.css`, `templates/preferences.html`, `tests/e2e/test_ui.py`, `tests/manual_checklist.md`
  - untracked: `.claude/launch.json`, `.claude/skills/debug/`, `AppIcon.icns.bak`, `HANDOFF_CLAUDE_SPARKLE.md`, `HANDOFF_CLAUDE_V221_UIUX_VERIFICATION.md`, `WhisperAI_ProductSpec_v1.md`, `docs/`, `poc_audio/`, `whisper_server.log`
- 這些不是此次 handoff 要清理的範圍

## Claude Code Mission

### 1. Inspect Before Acting

先讀以下文件，確認 scope 與設計方向，不要自行重開方向討論：

```bash
sed -n '1,220p' docs/Whisper_macOS_UI_Layout_Spec_v1.md
sed -n '1,220p' docs/Whisper_UI_Final_Direction_Decision_v1.md
sed -n '1,260p' docs/Whisper_UI_Implementation_Plan_v1.md
sed -n '1,260p' templates/index.html
sed -n '1,260p' static/app.css
sed -n '1,260p' static/app.js
```

要確認的事：

- 現有主畫面如何組成
- 哪些 DOM 可直接重組
- 哪些 class 命名可沿用
- `Notion` / `Obsidian` 現在如何顯示
- transcript tabs 與 action row 現在如何分離

### 2. Execute The Remaining Work

完成 `Phase 1 靜態改版`：

1. 依 implementation plan 重組 `templates/index.html`
2. 在 `static/app.css` 建立新版 app-shell、toolbar、capture panel、guidance strip、context bar、results workspace、action bar 樣式
3. 只在必要時更新 `static/app.js`，讓新 DOM 與既有功能接線不斷
4. 保留 Whisper 的薄荷綠、圓角卡片、mono tab 語感，但整體節奏朝更成熟商業版靠攏

### 3. Fix Only Findings In Scope

允許的修正：

- DOM 結構重排
- class / container 層級調整
- CSS tokens、spacing、surface、button hierarchy、workspace styling
- 少量 JS selector / class toggle / empty-state 文案調整

不允許的修正：

- 改 API contract
- 改資料流設計
- 重寫模式切換邏輯
- 改 Preferences 架構
- 改 release / Sparkle / packaging

### 4. Compare AC Source

Confirm that edits stay within the locked AC source.

- `Locked AC`: 視為 pass/fail gate
- `Extra suggested checks`: 可列出，但不可當成 blocking
- `Unauthorized AC`: 一律先停下來問 Alex

### 5. Re-run Verification

至少執行：

```bash
git status --short
node --check static/app.js
```

若專案現況允許，建議再做：

```bash
pytest -q tests/e2e/test_ui.py -k ui
```

以及手動檢查：

1. 主畫面是否已是五段式節奏
2. transcript 區與 action row 是否已整合
3. guidance strip 是否比原本卡片更精簡
4. 頂部整合狀態是否較像 toolbar 而非多個分散 toggle

## Report Back Format

```markdown
## Whisper UI Static Redesign Phase 1 Result

### Result
- Status: Ready / Not ready
- Completed:
- Blocked:

### Evidence
- <key evidence bullets>

### Fixes Made
- <file: summary>

### Remaining Risks
- <risks>

### Recommended Next Action
- <continue interaction polish / compact behavior / ask Alex>
```

## Do Not Do

- Do not run `git reset --hard`.
- Do not delete untracked files unless Alex explicitly asks.
- Do not clean the worktree.
- Do not expand this into Preferences refactor or backend refactor.
- Do not commit or push unless Alex asks.
- Do not change unrelated tests just to make this UI change appear complete.
- Do not treat optional polish as release-blocking AC.
- Do not accept unauthorized AC without Alex approval.

## Useful Context

- Layout spec:
  - `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/docs/Whisper_macOS_UI_Layout_Spec_v1.md`
- Final direction:
  - `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/docs/Whisper_UI_Final_Direction_Decision_v1.md`
- Implementation plan:
  - `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/docs/Whisper_UI_Implementation_Plan_v1.md`
- Existing related handoff:
  - `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/HANDOFF_CLAUDE_V221_UIUX_VERIFICATION.md`

請依照 `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/HANDOFF_CLAUDE_WHISPER_UI_STATIC_REDESIGN_PHASE1.md` 完成 Whisper UI 靜態改版第一階段。
