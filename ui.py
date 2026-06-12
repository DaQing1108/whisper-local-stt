"""ui.py — 內嵌前端 HTML。"""
HTML_PAGE = r"""<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Whisper 語音轉文字</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap">
<style>
  :root {
    --bg:       #0d0f14;
    --surface:  #161923;
    --card:     #1e2333;
    --border:   #2a3045;
    --accent:   #7c6aff;
    --accent2:  #a78bfa;
    --green:    #34d399;
    --red:      #f87171;
    --yellow:   #fbbf24;
    --text:     #e2e8f0;
    --muted:    #64748b;
    --radius:   16px;
  }
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Inter', sans-serif;
    background: radial-gradient(circle at top, #14112e 0%, var(--bg) 60%) no-repeat;
    background-color: var(--bg);
    color: var(--text);
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
  }

  /* ── Header ── */
  header {
    width: 100%;
    padding: 24px 32px;
    display: flex;
    align-items: center;
    gap: 12px;
    border-bottom: 1px solid var(--border);
    background: rgba(22,25,35,.8);
    backdrop-filter: blur(12px);
    position: sticky; top: 0; z-index: 10;
  }
  header .logo { font-size: 22px; }
  header h1 { font-size: 18px; font-weight: 600; letter-spacing: -.3px; }
  header .badge {
    margin-left: auto;
    font-size: 12px; padding: 4px 10px; border-radius: 20px;
    background: rgba(30,35,51,0.6); border: 1px solid var(--border); color: var(--muted);
    display: flex; align-items: center; cursor: default;
    transition: all 0.3s ease;
  }
  header .badge.ok { color: var(--green); border-color: rgba(52, 211, 153, 0.4); background: rgba(52, 211, 153, 0.05); }
  
  .status-dot {
    display: inline-block; width: 6px; height: 6px;
    border-radius: 50%; margin-right: 6px;
    background: var(--muted);
  }
  header .badge.ok .status-dot {
    background: var(--green);
    box-shadow: 0 0 6px var(--green);
    animation: pulse-dot 2s infinite;
  }
  @keyframes pulse-dot {
    0% { box-shadow: 0 0 0 0 rgba(52, 211, 153, 0.4); }
    70% { box-shadow: 0 0 0 4px rgba(52, 211, 153, 0); }
    100% { box-shadow: 0 0 0 0 rgba(52, 211, 153, 0); }
  }

  /* ── Layout ── */
  main.dashboard-layout {
    width: 100%; max-width: 1200px;
    padding: 32px 24px 80px;
    display: grid;
    grid-template-columns: 340px 1fr;
    gap: 24px;
    align-items: start;
  }
  @media (max-width: 860px) {
    main.dashboard-layout {
      grid-template-columns: 1fr;
    }
  }

  /* ── Card ── */
  .card {
    background: rgba(30, 35, 51, 0.6);
    backdrop-filter: blur(20px);
    border: 1px solid rgba(255, 255, 255, 0.05);
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
    border-radius: var(--radius);
    padding: 24px;
    display: flex; flex-direction: column; gap: 16px;
    transition: transform 0.2s, box-shadow 0.2s;
  }
  .card:hover {
    box-shadow: 0 12px 40px rgba(0, 0, 0, 0.5);
  }
  .card-title {
    font-size: 14px; font-weight: 700;
    text-transform: uppercase; letter-spacing: 1px;
    color: var(--muted);
  }

  /* ── Sidebar Forms ── */
  .settings-form {
    display: flex; flex-direction: column; gap: 16px;
  }
  .settings-form > div.flex-col {
    display: flex; flex-direction: column; gap: 6px;
  }
  .controls {
    display: flex; gap: 12px; flex-wrap: wrap; align-items: center;
  }
  select, input[type=text], input[type=password] {
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 8px 12px;
    border-radius: 8px;
    font-size: 14px;
    outline: none;
    transition: border-color .2s;
  }
  select:focus, input:focus { border-color: var(--accent); }
  label { font-size: 13px; color: var(--muted); }

  /* ── Record Area ── */
  .record-area {
    position: relative;
    width: 100%;
  }
  /* ── Record button ── */
  #record-btn {
    width: 100%;
    height: 160px;
    border-radius: var(--radius);
    border: 2px solid rgba(124,106,255,0.4);
    background: linear-gradient(135deg, rgba(124,106,255,.15), rgba(167,139,250,.05));
    color: var(--accent2);
    font-size: 20px; font-weight: 600;
    cursor: pointer;
    display: flex; flex-direction: column;
    align-items: center; justify-content: center; gap: 12px;
    transition: all .25s cubic-bezier(0.4, 0, 0.2, 1);
    position: relative; overflow: hidden;
    box-shadow: 0 4px 20px rgba(124,106,255,0.1);
  }
  #record-btn:hover { 
    background: linear-gradient(135deg, rgba(124,106,255,.25), rgba(167,139,250,.1));
    transform: translateY(-2px);
    box-shadow: 0 8px 30px rgba(124,106,255,0.2);
  }
  #record-btn.recording {
    border-color: var(--red);
    background: linear-gradient(135deg, rgba(248,113,113,.15), rgba(239,68,68,.05));
    color: var(--red);
    animation: pulse-border 2s cubic-bezier(0.4, 0, 0.6, 1) infinite;
  }
  #record-btn.processing {
    border-color: var(--yellow);
    color: var(--yellow);
    pointer-events: none;
    transform: scale(0.98);
  }
  @keyframes pulse-border {
    0% { box-shadow: 0 0 0 0 rgba(248,113,113,.4), inset 0 0 20px rgba(248,113,113,0.2); }
    70% { box-shadow: 0 0 0 15px rgba(248,113,113,0), inset 0 0 40px rgba(248,113,113,0.4); }
    100% { box-shadow: 0 0 0 0 rgba(248,113,113,0), inset 0 0 20px rgba(248,113,113,0.2); }
  }
  .btn-icon { font-size: 32px; line-height: 1; }
  .btn-label { font-size: 14px; }

  /* ── Toast Notifications ── */
  #toast-container {
    position: fixed; bottom: 24px; right: 24px;
    display: flex; flex-direction: column; gap: 10px; z-index: 9999;
  }
  .toast {
    background: rgba(30, 35, 51, 0.9);
    backdrop-filter: blur(10px);
    border: 1px solid var(--border);
    border-left: 4px solid var(--accent);
    color: var(--text); padding: 12px 16px; border-radius: 8px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
    font-size: 14px; display: flex; align-items: center; gap: 8px;
    animation: toast-slide-in 0.3s cubic-bezier(0.4, 0, 0.2, 1) forwards, toast-fade-out 0.3s cubic-bezier(0.4, 0, 0.2, 1) 2.7s forwards;
  }
  .toast.error { border-left-color: var(--red); }
  .toast.ok { border-left-color: var(--green); }
  @keyframes toast-slide-in {
    from { transform: translateX(100%); opacity: 0; }
    to { transform: translateX(0); opacity: 1; }
  }
  @keyframes toast-fade-out {
    from { opacity: 1; transform: translateX(0); }
    to { opacity: 0; transform: translateX(10px); }
  }

  /* ── Drag & Drop ── */
  .record-area.dragover #record-btn {
    border-color: var(--green);
    background: rgba(52, 211, 153, 0.15);
    transform: scale(1.02);
  }
  .record-area.dragover #btn-label::after {
    content: " (放開以轉錄)";
    color: var(--green);
  }

  /* ── Waveform ── */

  /* ── Processing Modal (Premium Design) ── */
  .modal-overlay {
    position: fixed; top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(8, 10, 16, 0.75);
    backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
    display: flex; align-items: center; justify-content: center;
    z-index: 10000;
    opacity: 0; pointer-events: none;
    transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
  }
  .modal-overlay.active { opacity: 1; pointer-events: auto; }
  .modal-overlay::before {
    content: ''; position: absolute; width: 800px; height: 800px;
    background: radial-gradient(circle, rgba(124, 106, 255, 0.12) 0%, transparent 60%);
    top: 50%; left: 50%; transform: translate(-50%, -50%);
    pointer-events: none; z-index: -1;
  }
  .modal-content {
    width: 480px; max-width: 90%;
    background: rgba(22, 24, 32, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.08);
    box-shadow: 0 30px 60px rgba(0,0,0,0.6), 0 0 0 1px rgba(124,106,255,0.1), inset 0 1px 0 rgba(255,255,255,0.05);
    transform: translateY(20px) scale(0.96);
    transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
    border-radius: 20px; padding: 24px;
    position: relative; overflow: hidden;
  }
  .modal-overlay.active .modal-content {
    transform: translateY(0) scale(1);
  }
  .modal-content::before {
    content: ''; position: absolute; top: 0; left: 0; right: 0; height: 4px;
    background: linear-gradient(90deg, var(--accent), #9b8cff, var(--accent));
    background-size: 200% 100%;
    animation: gradientShift 2s linear infinite;
  }
  .modal-header { display: flex; align-items: center; gap: 16px; border-bottom: 1px solid rgba(255,255,255,0.06); padding-bottom: 20px; margin-bottom: 20px; }
  .modal-header h3 { font-size: 16px; margin: 0; color: #fff; font-weight: 500; display: flex; align-items: center; letter-spacing: 0.5px; }
  .modal-timer-badge {
    font-family: monospace; font-size: 12px; font-weight: bold;
    color: #9b8cff; background: rgba(124, 106, 255, 0.15);
    padding: 4px 10px; border-radius: 20px; margin-left: 12px;
    letter-spacing: 1px; box-shadow: inset 0 0 0 1px rgba(124, 106, 255, 0.2);
  }
  .spinner-glow {
    width: 22px; height: 22px; border: 3px solid rgba(124,106,255,0.15);
    border-top-color: var(--accent); border-radius: 50%;
    animation: spin 1s linear infinite;
    box-shadow: 0 0 15px rgba(124,106,255,0.3);
  }
  @keyframes gradientShift { 0% { background-position: 0% 50%; } 100% { background-position: 200% 50%; } }
  .modal-logs {
    font-family: 'Inter', -apple-system, sans-serif; font-size: 13px; color: var(--muted);
    max-height: 300px; overflow-y: auto;
    display: flex; flex-direction: column; gap: 10px;
    padding-right: 8px;
  }
  .modal-logs::-webkit-scrollbar { width: 6px; }
  .modal-logs::-webkit-scrollbar-track { background: rgba(0,0,0,0.1); border-radius: 4px; }
  .modal-logs::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.1); border-radius: 4px; }
  .modal-logs::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.2); }
  
  .modal-log-entry { 
    animation: slideUpFade 0.4s cubic-bezier(0.4, 0, 0.2, 1) forwards; 
    padding: 12px 14px; background: rgba(0,0,0,0.25); border-radius: 10px;
    display: flex; align-items: flex-start; gap: 12px;
    border: 1px solid rgba(255,255,255,0.03);
    opacity: 0; transform: translateY(10px);
    line-height: 1.5;
  }
  .modal-log-entry:last-child {
    background: rgba(124, 106, 255, 0.08);
    border: 1px solid rgba(124, 106, 255, 0.2);
    color: #e2e8f0;
  }
  .modal-log-entry:last-child::before {
    content: "⏳"; font-size: 14px; animation: pulse 2s infinite; display: inline-block; filter: hue-rotate(-20deg) saturate(2);
  }
  .modal-log-entry:not(:last-child)::before {
    content: "✓"; font-size: 14px; color: var(--green); display: inline-block; font-weight: bold; text-shadow: 0 0 10px rgba(52, 211, 153, 0.5);
  }

  /* ── Status bar ── */
  #status-bar {
    font-size: 13px; color: var(--muted);
    padding: 10px 14px;
    background: var(--surface);
    border-radius: 8px;
    min-height: 40px;
    display: flex; align-items: center; gap: 8px;
  }
  #status-bar.ok    { color: var(--green); }
  #status-bar.error { color: var(--red); }

  /* ── Timer ── */
  #timer {
    font-variant-numeric: tabular-nums;
    font-size: 13px; color: var(--red);
    display: none;
  }
  #timer.active { display: inline; }

  /* ── Transcript ── */
  #transcript-box {
    min-height: 250px; max-height: 600px;
    overflow-y: auto;
    background: rgba(22, 25, 35, 0.4);
    border-radius: 10px;
    padding: 20px;
    font-size: 16px; line-height: 1.8;
    white-space: pre-wrap;
    color: var(--text);
    position: relative;
    border: 1px inset rgba(255,255,255,0.02);
  }
  #transcript-box:empty::before {
    content: '轉錄結果會出現在這裡…';
    color: var(--muted); font-style: italic;
  }
  @keyframes slideUpFade {
    from { opacity: 0; transform: translateY(15px); }
    to { opacity: 1; transform: translateY(0); }
  }
  .transcript-entry {
    margin-bottom: 16px;
    animation: slideUpFade 0.4s ease-out forwards;
  }
  .transcript-time  { font-size: 12px; color: var(--muted); margin-bottom: 6px; font-weight: 500; }
  .transcript-text  { font-size: 16px; letter-spacing: 0.2px; }

  /* ── Action buttons ── */
  .actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
  .export-item {
    padding: 7px 12px; font-size: 13px; cursor: pointer;
    border-radius: 7px; color: var(--text);
    transition: background .15s;
  }
  .export-item:hover { background: var(--surface); }
  .history-item {
    padding: 10px 12px; border-radius: 8px; cursor: pointer;
    border: 1px solid var(--border); margin-bottom: 8px;
    transition: background .15s;
  }
  .history-item:hover { background: var(--surface); }
  .history-item-meta { font-size: 11px; color: var(--muted); margin-bottom: 4px; }
  .history-item-preview { font-size: 13px; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .btn {
    padding: 9px 18px; border-radius: 8px;
    font-size: 14px; font-weight: 500;
    border: 1px solid var(--border);
    cursor: pointer; transition: all .2s;
    background: var(--surface); color: var(--text);
  }
  .btn:hover { border-color: var(--accent); color: var(--accent2); }
  .btn.primary {
    background: var(--accent); border-color: var(--accent);
    color: #fff;
  }
  .btn.primary:hover { background: var(--accent2); border-color: var(--accent2); }
  .btn:disabled { opacity: .4; cursor: not-allowed; }

  /* ── Settings panel ── */
  .settings-grid {
    display: grid; grid-template-columns: 1fr 1fr; gap: 16px;
  }
  .field { display: flex; flex-direction: column; gap: 6px; }
  .field label { font-size: 12px; color: var(--muted); font-weight: 500; }
  .field input { width: 100%; }
  .settings-grid .full { grid-column: 1 / -1; }

  /* ── Tag Manager UI ── */
  .tag-input-box {
    display: flex; flex-wrap: wrap; gap: 6px;
    background: var(--surface2, #1a1d27);
    border: 1px solid var(--border); border-radius: 8px;
    padding: 6px; min-height: 38px; align-items: center;
    transition: border-color 0.2s;
  }
  .tag-input-box:focus-within { border-color: var(--accent); }
  .tag-input-box input {
    flex: 1; min-width: 120px; border: none; background: transparent;
    color: var(--text); font-size: 13px; outline: none; padding: 4px;
  }
  .tag-chip {
    display: inline-flex; align-items: center; gap: 4px;
    background: rgba(124,106,255,0.15); color: var(--accent2);
    border: 1px solid rgba(124,106,255,0.3); border-radius: 6px;
    padding: 2px 8px; font-size: 12px; font-weight: 500;
    transition: all 0.2s; user-select: none;
  }
  .tag-chip:hover { background: rgba(124,106,255,0.25); }
  .tag-chip .rm-btn {
    cursor: pointer; opacity: 0.6; font-size: 14px; line-height: 1;
    display: inline-block; padding-left: 2px;
  }
  .tag-chip .rm-btn:hover { opacity: 1; color: #fff; }

  /* ── Saved Dictionary Library ── */
  .saved-dict {
    margin-top: 10px; padding: 12px;
    background: rgba(255,255,255,0.02);
    border: 1px dashed var(--border); border-radius: 8px;
  }
  .saved-dict-header {
    display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 8px; font-size: 12px; color: var(--muted);
    cursor: pointer; user-select: none;
  }
  .saved-dict-header:hover { color: var(--text); }
  .dict-chip {
    display: inline-flex; align-items: center; gap: 4px;
    background: var(--surface); color: var(--text);
    border: 1px solid var(--border); border-radius: 12px;
    padding: 3px 10px; font-size: 12px; cursor: pointer;
    transition: all 0.2s; user-select: none;
  }
  .dict-chip:hover { border-color: var(--accent); color: var(--accent2); }
  .dict-chip.active {
    background: var(--accent); border-color: var(--accent); color: #fff;
  }
  .dict-chip.active:hover { background: var(--accent2); }
  .dict-chip .del-dict-btn {
    cursor: pointer; opacity: 0.4; margin-left: 4px; font-size: 11px;
    padding: 2px; border-radius: 50%; line-height: 1;
  }
  .dict-chip .del-dict-btn:hover { opacity: 1; color: #ff6b6b; background: rgba(255,0,0,0.1); }
  .dict-chips-container {
    display: flex; flex-wrap: wrap; gap: 6px;
  }

  /* ── Toggle ── */
  .toggle-row {
    display: flex; align-items: center; gap: 10px;
    font-size: 14px;
  }
  .toggle {
    width: 38px; height: 22px;
    background: var(--border); border-radius: 11px;
    cursor: pointer; position: relative; transition: background .2s;
    border: none;
  }
  .toggle::after {
    content: ''; position: absolute;
    width: 16px; height: 16px; border-radius: 50%;
    background: #fff; top: 3px; left: 3px;
    transition: left .2s;
  }
  .toggle.on { background: var(--accent); }
  .toggle.on::after { left: 19px; }

  /* ── Scrollbar ── */
  ::-webkit-scrollbar { width: 6px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
</style>
</head>
<body>

<header>
  <span class="logo">🎙️</span>
  <h1>Whisper 語音轉文字</h1>
  <span id="app-version" style="font-size:11px;opacity:.45;margin-right:auto;margin-left:6px;"></span>
  <span class="badge" id="notion-badge" title="未連線"><span class="status-dot"></span><span id="notion-badge-text">Notion 未連線</span></span>
</header>

<main class="dashboard-layout">

  <!-- Left Sidebar: Settings -->
  <aside class="sidebar">
    <div class="card">
      <div class="card-title">⚙️ 錄音設定</div>
      <div class="settings-form">
        <div class="flex-col">
          <label>模型</label>
          <select id="model-sel">
            <option value="tiny">tiny（最快）</option>
            <option value="base">base</option>
            <option value="small" selected>small（推薦）</option>
            <option value="medium">medium（最準）</option>
          </select>
        </div>
        <div class="flex-col">
          <label>語言</label>
          <select id="lang-sel">
            <option value="auto">自動偵測</option>
            <option value="zh" selected>中文</option>
            <option value="en">英文</option>
            <option value="ja">日文</option>
          </select>
        </div>
        <div class="flex-col">
          <label>領域</label>
          <select id="domain-sel">
            <option value="general">通用</option>
            <option value="media">媒體／廣電</option>
            <option value="tech">科技</option>
            <option value="medical">醫療</option>
            <option value="legal">法律</option>
          </select>
        </div>
        
        <div class="flex-col">
          <label>自訂專有名詞庫 <span style="color:var(--muted);font-size:11px">（按 Enter 新增）</span></label>
          <!-- Input area where active tags go -->
          <div class="tag-input-box" onclick="document.getElementById('tag-input-field').focus()">
            <div id="active-tags-container" style="display:contents"></div>
            <input id="tag-input-field" type="text" placeholder="輸入專有名詞...">
          </div>
          <!-- Hidden input for form submission -->
          <input type="hidden" id="extra-terms">

          <!-- Saved Dictionary Area -->
          <div class="saved-dict">
            <div class="saved-dict-header" onclick="toggleSavedDict()">
              <span id="saved-dict-title">📌 常用詞庫 (點擊展開) <span style="font-size:10px;margin-left:4px">▶</span></span>
              <button class="btn" style="padding:2px 6px;font-size:10px;background:transparent;border-color:transparent" onclick="clearVocabLibrary(event)" title="還原預設詞庫">↺ 重設</button>
            </div>
            <div id="vocab-tags-container" class="dict-chips-container" style="display:none; transition: all 0.3s ease;">
              <!-- Saved tags dynamically generated here -->
            </div>
          </div>
        </div>

        <div style="height:1px; background:var(--border); margin: 8px 0;"></div>

        <div class="flex-col" style="flex-direction:row; align-items:center; justify-content:space-between">
          <label>自動上傳 Notion</label>
          <div class="toggle-row">
            <span id="notion-toggle-label" style="font-size:13px;color:var(--muted)">關閉</span>
            <button class="toggle" id="notion-toggle" onclick="toggleNotion()"></button>
          </div>
        </div>
        <div class="flex-col" style="flex-direction:row; align-items:center; justify-content:space-between">
          <label>存入 Obsidian</label>
          <div class="toggle-row">
            <span id="obsidian-toggle-label" style="font-size:13px;color:var(--muted)">關閉</span>
            <button class="toggle" id="obsidian-toggle" onclick="toggleObsidian()"></button>
          </div>
        </div>
      </div>
    </div>

    <!-- Notion 設定 card -->
    <div class="card" id="settings-card" style="margin-top: 24px;">
      <div class="card-title">Notion 設定</div>
      <div class="settings-grid">
        <div class="field full">
          <label>Integration Token (secret_xxx)</label>
          <input type="password" id="notion-token" placeholder="secret_xxxxxxxxxxxxxxxx">
        </div>
        <div class="field full">
          <label>目標頁面 ID（URL 最後 32 碼）</label>
          <input type="text" id="notion-page-id" placeholder="37a280a95f76810b90d0e6cad40786fa">
        </div>
      </div>
      <div style="margin-top:14px;display:flex;gap:10px;align-items:center">
        <button class="btn primary" onclick="saveConfig()">驗證並儲存</button>
        <span id="config-status" style="font-size:13px;color:var(--muted)"></span>
      </div>
    </div>
  </aside>

  <!-- Right Workspace: Recording and Transcripts -->
  <section class="workspace" style="display:flex; flex-direction:column; gap:24px;">
    <!-- 核心錄音區塊 -->
    <div class="card" style="padding: 32px;">
      <div class="record-area">
        <canvas id="waveform" style="position:absolute; bottom:0; left:0; right:0; opacity:0.6; height:100%; border-radius:var(--radius); pointer-events:none; z-index:1; mix-blend-mode:screen;"></canvas>
        <button id="record-btn" onclick="toggleRecord()" style="z-index:2;">
          <span class="btn-icon" id="btn-icon">🎤</span>
          <span class="btn-label" id="btn-label">點擊開始錄音</span>
          <span id="timer"></span>
        </button>
      </div>
      <div id="status-bar" style="margin-top:20px; justify-content:center; background: transparent;">等待錄音…</div>
    </div>

    <!-- 轉錄結果 card -->
    <div class="card">
      <div class="card-title" style="display:flex; justify-content:space-between;">
        <span>📝 轉錄結果</span>
        <span style="font-size:11px; color:var(--muted); font-weight:normal; text-transform:none;">(點擊內文可直接修改)</span>
      </div>
      <div id="transcript-box" contenteditable="true" spellcheck="false" style="outline:none;"></div>
      <audio id="local-audio-player" controls style="display:none; width:100%; margin-top:10px; height:32px; border-radius:8px; opacity:0.8;"></audio>
      <div class="actions" style="margin-top:14px">
        <button class="btn primary" id="upload-btn" onclick="uploadToNotion()" disabled>
          📤 上傳至 Notion
        </button>
        <button class="btn" onclick="copyTranscript()">📋 複製</button>
        <div class="export-wrap" style="position:relative;display:inline-block;">
          <button class="btn" id="export-btn" onclick="toggleExportMenu()" disabled>⬇️ 匯出</button>
          <div id="export-menu" style="display:none;position:absolute;bottom:110%;left:0;background:var(--surface2);border:1px solid var(--border);border-radius:10px;padding:6px;min-width:140px;z-index:99;box-shadow:0 4px 16px rgba(0,0,0,.3);">
            <div class="export-item" onclick="exportAs('txt')">📄 純文字 .txt</div>
            <div class="export-item" onclick="exportAs('srt')">🎬 字幕 .srt</div>
            <div class="export-item" onclick="exportAs('md')">📝 Markdown .md</div>
          </div>
        </div>
        <button class="btn" id="obsidian-btn" onclick="saveToObsidian()" disabled>🟣 存入 Obsidian</button>
        <button class="btn" onclick="clearTranscript()">🗑 清除</button>
        <button class="btn" id="history-btn" onclick="toggleHistory()" style="margin-left:auto;">🕓 歷史</button>
      </div>
    </div>

    <!-- 歷史記錄面板 -->
    <div id="history-panel" style="display:none;" class="card">
      <div class="card-title" style="display:flex;justify-content:space-between;align-items:center;">
        <span>🕓 轉錄歷史</span>
        <button class="btn" onclick="clearHistory()" style="padding:2px 8px;font-size:11px;">清除全部</button>
      </div>
      <div id="history-list" style="max-height:300px;overflow-y:auto;"></div>
    </div>
  </section>

</main>
<div id="toast-container"></div>

<!-- 處理進度 Modal -->
<div id="processing-modal" class="modal-overlay">
  <div class="modal-content">
    <div class="modal-header">
      <div class="spinner-glow"></div>
      <h3 style="flex:1">AI 雲端語音分析中 <span id="modal-timer" class="modal-timer-badge">00:00</span></h3>
      <button class="btn" style="padding:6px 12px; font-size:12px; background:rgba(255,255,255,0.05); border:1px solid rgba(255,255,255,0.1); border-radius:12px; color:var(--muted); cursor:pointer;" onclick="hideProcessingModal()">隱藏背景</button>
    </div>
    <div id="processing-logs" class="modal-logs"></div>
  </div>
</div>

<script>
// ── State ─────────────────────────────────────────────────────
let mediaRecorder = null
let audioChunks   = []
let isRecording   = false
let timerInterval = null
let timerSec      = 0
let lastText      = ''
let lastLang      = ''
let notionEnabled   = false
let obsidianEnabled = false

const SESSION_KEY = 'whisper_session'

function _saveSession() {
  const box = document.getElementById('transcript-box')
  if (!box) return
  localStorage.setItem(SESSION_KEY, JSON.stringify({
    html: box.innerHTML,
    text: lastText,
    lang: lastLang,
    segments: _exportSegments || [],
    ts: Date.now()
  }))
}

function _restoreSession() {
  try {
    const raw = localStorage.getItem(SESSION_KEY)
    if (!raw) return
    const s = JSON.parse(raw)
    // 只還原 6 小時內的 session
    if (Date.now() - s.ts > 6 * 3600 * 1000) return
    if (!s.html) return
    const box = document.getElementById('transcript-box')
    box.innerHTML = s.html
    lastText = s.text || ''
    lastLang = s.lang || ''
    _exportSegments = s.segments || []
    _syncExportBtn()
    syncUploadBtn()
  } catch(e) {}
}

let notionReady   = false

// ── SSE ──────────────────────────────────────────────────────
const evtSrc = new EventSource('/events')
evtSrc.addEventListener('status', e => {
  const d = JSON.parse(e.data)
  setStatus(d.msg)
})
evtSrc.addEventListener('transcript', e => {
  const d = JSON.parse(e.data)
  addTranscript(d.text, d.language, d.time)
  _exportSegments = d.segments || []
  _syncExportBtn()
  saveToHistory(d.text, d.language, d.segments || [])
})
evtSrc.addEventListener('chunk', e => {
  const d = JSON.parse(e.data)
  const box = document.getElementById('transcript-box')
  const entry = document.createElement('div')
  entry.className = 'transcript-entry'
  const now = new Date().toTimeString().slice(0,8)
  entry.innerHTML = `<div class="transcript-time" contenteditable="false">${now}｜第 ${d.chunk}/${d.total} 段</div>
                     <div class="transcript-text">${escHtml(d.text)}</div>`
  box.appendChild(entry)
  box.scrollTop = box.scrollHeight
  lastText = Array.from(box.querySelectorAll('.transcript-text')).map(el => el.textContent).join('\n')
  syncUploadBtn()
})

// 監聽文字即時修改
document.getElementById('transcript-box').addEventListener('input', (e) => {
  lastText = Array.from(e.currentTarget.querySelectorAll('.transcript-text')).map(el => el.textContent).join('\n') || e.currentTarget.innerText;
  syncUploadBtn();
  _saveSession();
});


// ── Init ──────────────────────────────────────────────────────
let defaultVocabs = ["DGX", "健康2.0", "TVBS", "Bag & Pulse", "ASR", "Claude Code"];

window.onload = async () => {
  _restoreSession()
  await checkConfig();
  loadVocabLibrary();
  renderHistory();
  fetch('/api/version').then(r => r.json()).then(d => {
    const el = document.getElementById('app-version');
    if (el) el.textContent = 'v' + d.version;
  }).catch(() => {});
};

function getVocabLibrary() {
  let lib = localStorage.getItem('whisper_vocab_library');
  if (!lib) {
    lib = JSON.stringify(defaultVocabs);
    localStorage.setItem('whisper_vocab_library', lib);
  }
  return JSON.parse(lib);
}

function saveVocabLibrary(lib) {
  localStorage.setItem('whisper_vocab_library', JSON.stringify(lib));
  renderVocabTags();
}

function loadVocabLibrary() {
  renderVocabTags();
  renderActiveTags();
}

let activeVocabs = [];

function renderActiveTags() {
  const container = document.getElementById('active-tags-container');
  container.innerHTML = '';
  activeVocabs.forEach(term => {
    const chip = document.createElement('span');
    chip.className = 'tag-chip';
    chip.innerHTML = `${term} <span class="rm-btn" onclick="removeActiveTag('${term.replace(/'/g, "\\'")}')">×</span>`;
    container.appendChild(chip);
  });
  document.getElementById('extra-terms').value = activeVocabs.join(', ');
  // Re-render library to update active states
  renderVocabTags();
}

function removeActiveTag(term) {
  activeVocabs = activeVocabs.filter(t => t !== term);
  renderActiveTags();
}

function renderVocabTags() {
  const container = document.getElementById('vocab-tags-container');
  container.innerHTML = '';
  const lib = getVocabLibrary();
  
  lib.forEach(term => {
    const isActive = activeVocabs.includes(term);
    const chip = document.createElement('span');
    chip.className = `dict-chip ${isActive ? 'active' : ''}`;
    
    // Clicking the chip toggles it in the active list
    chip.onclick = () => {
      if (isActive) {
        activeVocabs = activeVocabs.filter(t => t !== term);
      } else {
        activeVocabs.push(term);
      }
      renderActiveTags();
    };
    
    chip.innerHTML = `${term} <span class="del-dict-btn" onclick="removeVocabFromLibrary(event, '${term.replace(/'/g, "\\'")}')">×</span>`;
    container.appendChild(chip);
  });
}

function removeVocabFromLibrary(e, term) {
  e.stopPropagation(); // Prevent triggering the chip click
  if (confirm(`確定從常用詞庫移除「${term}」？`)) {
    let lib = getVocabLibrary();
    lib = lib.filter(t => t !== term);
    saveVocabLibrary(lib);
  }
}

function clearVocabLibrary(e) {
  if (e) e.stopPropagation();
  if (confirm("是否還原預設常用詞庫？")) {
    localStorage.removeItem('whisper_vocab_library');
    renderVocabTags();
  }
}

let isSavedDictExpanded = false;
function toggleSavedDict() {
  isSavedDictExpanded = !isSavedDictExpanded;
  const container = document.getElementById('vocab-tags-container');
  const title = document.getElementById('saved-dict-title');
  if (isSavedDictExpanded) {
    container.style.display = 'flex';
    title.innerHTML = '📌 常用詞庫 (點擊收合) <span style="font-size:10px;margin-left:4px">▼</span>';
  } else {
    container.style.display = 'none';
    title.innerHTML = '📌 常用詞庫 (點擊展開) <span style="font-size:10px;margin-left:4px">▶</span>';
  }
}

// Handle Enter key in tag input
document.getElementById('tag-input-field').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault();
    const term = e.target.value.trim();
    if (term && !activeVocabs.includes(term)) {
      activeVocabs.push(term);
      // Auto save to library if not exists
      let lib = getVocabLibrary();
      if (!lib.includes(term)) {
        lib.push(term);
        saveVocabLibrary(lib);
      }
      renderActiveTags();
    }
    e.target.value = '';
  } else if (e.key === 'Backspace' && e.target.value === '' && activeVocabs.length > 0) {
    // Optional: Backspace to remove last tag
    activeVocabs.pop();
    renderActiveTags();
  }
});

async function checkConfig() {
  try {
    const r = await fetch('/config').then(r => r.json())
    notionReady = r.ready
    const badge = document.getElementById('notion-badge')
    const badgeText = document.getElementById('notion-badge-text')
    if (r.ready) {
      const label = r.page_label && r.page_label !== r.page_id ? r.page_label : r.page_id
      badgeText.textContent = `Notion｜${label}`
      badge.title = `頁面 ID：${r.page_id}`
      badge.className = 'badge ok'
    } else {
      badgeText.textContent = 'Notion 未連線'
      badge.title = '未配置或連線失敗'
      badge.className = 'badge'
    }
    syncUploadBtn()
  } catch(e) {}
}

// ── Notion toggle ─────────────────────────────────────────────
function toggleNotion() {
  notionEnabled = !notionEnabled
  const btn = document.getElementById('notion-toggle')
  const lbl = document.getElementById('notion-toggle-label')
  btn.className = 'toggle' + (notionEnabled ? ' on' : '')
  lbl.textContent = notionEnabled ? '開啟' : '關閉'
}

function toggleObsidian() {
  obsidianEnabled = !obsidianEnabled
  const btn = document.getElementById('obsidian-toggle')
  const lbl = document.getElementById('obsidian-toggle-label')
  btn.className = 'toggle' + (obsidianEnabled ? ' on' : '')
  lbl.textContent = obsidianEnabled ? '開啟' : '關閉'
}

// ── Record ────────────────────────────────────────────────────
async function toggleRecord() {
  if (isRecording) {
    stopRecording()
  } else {
    await startRecording()
  }
}

async function startRecording() {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    audioChunks  = []
    mediaRecorder = new MediaRecorder(stream)
    mediaRecorder.ondataavailable = e => {
      if (e.data.size > 0) audioChunks.push(e.data)
    }
    mediaRecorder.onstop = () => sendAudio(stream)
    mediaRecorder.start(100)

    isRecording = true
    startWaveform(stream)
    startTimer()
    setRecordingUI(true)
    setStatus('🔴 錄音中…按下停止以轉錄')
  } catch(e) {
    setStatus(`❌ 無法存取麥克風：${e.message}`, 'error')
  }
}

function stopRecording() {
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    mediaRecorder.stop()
  }
  isRecording = false
  stopTimer()
  stopWaveform()
  setRecordingUI(false)
  setStatus('⏳ 處理中…')
  
  if (audioChunks.length > 0) {
    const blob = new Blob(audioChunks, { type: 'audio/webm' });
    const player = document.getElementById('local-audio-player');
    player.src = URL.createObjectURL(blob);
    player.style.display = 'block';
  }
}

async function sendAudio(stream) {
  stream.getTracks().forEach(t => t.stop())
  const blob = new Blob(audioChunks, { type: 'audio/webm' })
  await uploadFileBlob(blob, 'recording.webm')
}

async function uploadFileBlob(blob, filename='upload.webm') {
  const form = new FormData()
  form.append('audio', blob, filename)
  form.append('model', document.getElementById('model-sel').value)
  form.append('language', document.getElementById('lang-sel').value)
  form.append('domain', document.getElementById('domain-sel').value)
  form.append('extra_terms', document.getElementById('extra-terms').value)
  form.append('obsidian', obsidianEnabled ? 'true' : 'false')

  setBtnState('processing')
  setStatus('⏳ 上傳檔案中…')

  try {
    const r = await fetch('/transcribe', { method: 'POST', body: form })
    if (!r.ok) {
      const d = await r.json()
      throw new Error(d.error || '上傳失敗')
    }
  } catch(e) {
    setStatus(`❌ ${e.message}`, 'error')
    setBtnState('idle')
    syncUploadBtn()
  }
}

// ── Drag & Drop ───────────────────────────────────────────────
const recordArea = document.querySelector('.record-area');
recordArea.addEventListener('dragover', e => {
  e.preventDefault();
  recordArea.classList.add('dragover');
});
recordArea.addEventListener('dragleave', e => {
  e.preventDefault();
  recordArea.classList.remove('dragover');
});
recordArea.addEventListener('drop', e => {
  e.preventDefault();
  recordArea.classList.remove('dragover');
  if (isRecording) {
    setStatus('⚠️ 錄音中，無法拖曳檔案', 'error');
    return;
  }
  
  const file = e.dataTransfer.files[0];
  if (file && (file.type.startsWith('audio/') || file.type.startsWith('video/'))) {
    // 設置播放器
    const player = document.getElementById('local-audio-player');
    player.src = URL.createObjectURL(file);
    player.style.display = 'block';
    
    // 直接上傳
    audioChunks = [file];
    uploadFileBlob(file, file.name);
  } else {
    setStatus('❌ 請拖曳音訊或影片檔案', 'error');
  }
});

// SSE done 事件：轉錄背景完成後觸發
evtSrc.addEventListener('done', async e => {
  const d = JSON.parse(e.data)
  setBtnState('idle')
  hideProcessingModal()
  
  if (!d.ok) {
    if (d.error !== 'empty') setStatus(`❌ ${d.error}`, 'error')
    syncUploadBtn()
    return
  }
  lastText = d.text
  lastLang = d.language
  syncUploadBtn()
  setStatus('✅ 轉錄完成', 'ok')
  if (notionEnabled && notionReady) {
    await doUpload(d.text, d.language)
  }
})

// ── Upload ────────────────────────────────────────────────────
async function uploadToNotion() {
  if (!lastText) return
  await doUpload(lastText, lastLang)
}

async function doUpload(text, lang) {
  const pageId = document.getElementById('notion-page-id').value.trim()
    || null
  setStatus('📤 上傳至 Notion…')
  try {
    const r = await fetch('/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, language: lang, page_id: pageId }),
    })
    const d = await r.json()
    if (!r.ok) throw new Error(d.error)
    setStatus(`✅ 已上傳至 Notion（${d.blocks} blocks）`, 'ok')
  } catch(e) {
    setStatus(`❌ 上傳失敗：${e.message}`, 'error')
  }
}

// ── Transcript UI ─────────────────────────────────────────────
function addTranscript(text, lang, time) {
  const box = document.getElementById('transcript-box')
  const entry = document.createElement('div')
  entry.className = 'transcript-entry'
  entry.innerHTML = `<div class="transcript-time">${time}｜${lang}</div>
                     <div class="transcript-text">${escHtml(text)}</div>`
  box.appendChild(entry)
  box.scrollTop = box.scrollHeight
  lastText = text
  lastLang = lang
  syncUploadBtn()
  _syncExportBtn()
  _saveSession()
}

function copyTranscript() {
  const text = document.getElementById('transcript-box').innerText
  navigator.clipboard.writeText(text)
  setStatus('📋 已複製到剪貼簿', 'ok')
}

// ── O1: 匯出功能 ──────────────────────────────────────────────
let _exportSegments = []   // [{text, start, end}] 由後端回傳時儲存

function toggleExportMenu() {
  const m = document.getElementById('export-menu')
  m.style.display = m.style.display === 'none' ? 'block' : 'none'
}
document.addEventListener('click', e => {
  if (!e.target.closest('.export-wrap')) {
    const m = document.getElementById('export-menu')
    if (m) m.style.display = 'none'
  }
})

function _secToTimecode(s, srt=false) {
  const h = Math.floor(s/3600), m = Math.floor((s%3600)/60), sec = Math.floor(s%60), ms = Math.round((s%1)*1000)
  const pad = (n,d=2) => String(n).padStart(d,'0')
  return srt
    ? `${pad(h)}:${pad(m)}:${pad(sec)},${pad(ms,3)}`
    : `${pad(h)}:${pad(m)}:${pad(sec)}`
}

function exportAs(fmt) {
  document.getElementById('export-menu').style.display = 'none'
  const rawText = document.getElementById('transcript-box').innerText.trim()
  if (!rawText) return

  const now = new Date()
  const dateStr = now.toISOString().slice(0,10)
  const timeStr = now.toTimeString().slice(0,8).replace(/:/g,'-')
  let content = '', ext = fmt, mime = 'text/plain'

  if (fmt === 'txt') {
    content = rawText
  } else if (fmt === 'md') {
    content = `# 轉錄記錄 ${dateStr} ${now.toTimeString().slice(0,8)}\n\n${rawText}\n`
    mime = 'text/markdown'
  } else if (fmt === 'srt') {
    if (_exportSegments.length > 0) {
      content = _exportSegments.map((seg, i) => {
        const start = _secToTimecode(seg.start, true)
        const end   = _secToTimecode(seg.end,   true)
        return `${i+1}\n${start} --> ${end}\n${seg.text.trim()}\n`
      }).join('\n')
    } else {
      // 無 segment 資料時退回純文字格式
      content = rawText.split('\n').filter(l=>l.trim()).map((line, i) => {
        const t = i * 3
        return `${i+1}\n${_secToTimecode(t,true)} --> ${_secToTimecode(t+3,true)}\n${line}\n`
      }).join('\n')
    }
  }

  const blob = new Blob([content], {type: mime})
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `whisper_${dateStr}_${timeStr}.${ext}`
  a.click()
  URL.revokeObjectURL(a.href)
  setStatus(`⬇️ 已匯出 .${ext}`, 'ok')
}

function _syncExportBtn() {
  document.getElementById('export-btn').disabled = !lastText
  const ob = document.getElementById('obsidian-btn')
  if (ob) ob.disabled = !lastText
}

async function saveToObsidian() {
  const text = document.getElementById('transcript-box').innerText.trim()
  if (!text) return

  const btn = document.getElementById('obsidian-btn')
  btn.disabled = true
  btn.textContent = '🟣 存入中...'

  try {
    const res = await fetch('/api/save_to_obsidian', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        text,
        lang: lastLang || 'zh',
        meta: {}
      })
    })
    const d = await res.json()
    if (d.ok) {
      setStatus(`🟣 已存入 Obsidian，LLM 整理中：${d.filename}`, 'ok')
    } else {
      setStatus(`❌ 存入失敗：${d.error}`, 'error')
    }
  } catch(e) {
    setStatus(`❌ 網路錯誤：${e.message}`, 'error')
  } finally {
    btn.disabled = !lastText
    btn.textContent = '🟣 存入 Obsidian'
  }
}

// ── O2: 轉錄歷史 ─────────────────────────────────────────────
const HISTORY_KEY = 'whisper_history'
const HISTORY_MAX = 20

function saveToHistory(text, lang, segments) {
  const lib = JSON.parse(localStorage.getItem(HISTORY_KEY) || '[]')
  lib.unshift({ text, lang, segments: segments || [], ts: new Date().toISOString() })
  localStorage.setItem(HISTORY_KEY, JSON.stringify(lib.slice(0, HISTORY_MAX)))
  renderHistory()
}

function renderHistory() {
  const lib = JSON.parse(localStorage.getItem(HISTORY_KEY) || '[]')
  const list = document.getElementById('history-list')
  if (!lib.length) {
    list.innerHTML = '<div style="color:var(--muted);font-size:13px;padding:8px;">尚無歷史記錄</div>'
    return
  }
  list.innerHTML = lib.map((item, i) => {
    const dt = new Date(item.ts)
    const label = dt.toLocaleString('zh-TW',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'})
    const preview = item.text.slice(0, 60).replace(/\n/g,' ')
    return `<div class="history-item" onclick="restoreHistory(${i})">
      <div class="history-item-meta">${label}｜${item.lang}</div>
      <div class="history-item-preview">${escHtml(preview)}…</div>
    </div>`
  }).join('')
}

function restoreHistory(i) {
  const lib = JSON.parse(localStorage.getItem(HISTORY_KEY) || '[]')
  const item = lib[i]
  if (!item) return
  const box = document.getElementById('transcript-box')
  box.innerHTML = ''
  const entry = document.createElement('div')
  entry.className = 'transcript-entry'
  const ts = new Date(item.ts).toTimeString().slice(0,8)
  entry.innerHTML = `<div class="transcript-time">${ts}｜${item.lang}</div>
                     <div class="transcript-text">${escHtml(item.text)}</div>`
  box.appendChild(entry)
  lastText = item.text
  _exportSegments = item.segments || []
  _syncExportBtn()
  syncUploadBtn()
  toggleHistory()
  setStatus('🕓 已從歷史記錄還原', 'ok')
}

function clearHistory() {
  if (!confirm('確定清除所有歷史記錄？')) return
  localStorage.removeItem(HISTORY_KEY)
  renderHistory()
}

function toggleHistory() {
  const panel = document.getElementById('history-panel')
  const visible = panel.style.display !== 'none'
  panel.style.display = visible ? 'none' : 'block'
  if (!visible) renderHistory()
}

function clearTranscript() {
  document.getElementById('transcript-box').innerHTML = ''
  document.getElementById('local-audio-player').style.display = 'none'
  document.getElementById('local-audio-player').src = ''
  lastText = ''
  lastLang = ''
  _exportSegments = []
  localStorage.removeItem(SESSION_KEY)
  syncUploadBtn()
  _syncExportBtn()
}

function syncUploadBtn() {
  document.getElementById('upload-btn').disabled = !lastText
}

// ── Config ────────────────────────────────────────────────────
async function saveConfig() {
  const token  = document.getElementById('notion-token').value.trim()
  const pageId = document.getElementById('notion-page-id').value.trim()
  const statusEl = document.getElementById('config-status')
  statusEl.textContent = '驗證中…'
  try {
    const r = await fetch('/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token, page_id: pageId }),
    })
    const d = await r.json()
    if (!r.ok) throw new Error(d.error)
    statusEl.textContent = `✅ 已連線：${d.page_label}`
    statusEl.style.color = 'var(--green)'
    await checkConfig()
  } catch(e) {
    statusEl.textContent = `❌ ${e.message}`
    statusEl.style.color = 'var(--red)'
  }
}

// ── UI helpers ────────────────────────────────────────────────
function setRecordingUI(recording) {
  const btn   = document.getElementById('record-btn')
  const icon  = document.getElementById('btn-icon')
  const label = document.getElementById('btn-label')
  if (recording) {
    btn.className   = 'recording'
    icon.textContent  = '⏹'
    label.textContent = '錄音中⋯ 點擊停止'
  } else {
    btn.className   = ''
    icon.textContent  = '🎤'
    label.textContent = '點擊開始錄音'
  }
}

function setBtnState(state) {
  const btn   = document.getElementById('record-btn')
  const icon  = document.getElementById('btn-icon')
  const label = document.getElementById('btn-label')
  if (state === 'processing') {
    btn.className   = 'processing'
    icon.textContent  = '⏳'
    label.textContent = '轉錄中…'
    showProcessingModal()
  } else {
    btn.className   = ''
    icon.textContent  = '🎤'
    label.textContent = '點擊開始錄音'
  }
}

let modalTimerInterval = null;
let modalTimerSec = 0;

function showProcessingModal() {
  document.getElementById('processing-logs').innerHTML = '';
  document.getElementById('processing-modal').classList.add('active');
  
  modalTimerSec = 0;
  document.getElementById('modal-timer').textContent = '00:00';
  clearInterval(modalTimerInterval);
  modalTimerInterval = setInterval(() => {
    modalTimerSec++;
    const m = String(Math.floor(modalTimerSec/60)).padStart(2,'0');
    const s = String(modalTimerSec % 60).padStart(2,'0');
    document.getElementById('modal-timer').textContent = `${m}:${s}`;
  }, 1000);
}

function hideProcessingModal() {
  document.getElementById('processing-modal').classList.remove('active');
  clearInterval(modalTimerInterval);
}

function appendModalLog(msg) {
  // 過濾掉原本的 emoji，交給 CSS 統一處理 icon
  const cleanMsg = msg.replace(/^[\u231A\u23F3\u23F0\u2705\u274C\uD83D\uDCCB\uD83D\uDCE4\u26A0\uFE0F\uD83D\uDD5B\uD83E\uDD16]\s*/g, '');
  const logs = document.getElementById('processing-logs');
  const entry = document.createElement('div');
  entry.className = 'modal-log-entry';
  entry.textContent = cleanMsg;
  logs.appendChild(entry);
  logs.scrollTop = logs.scrollHeight;
}

function setStatus(msg, type = '') {
  const el = document.getElementById('status-bar')
  el.textContent = msg
  el.className = type
  
  // 若屬於背景處理流程，則寫入 Modal Log 而不是 Toast
  if (msg.includes('處理中') || msg.includes('上傳檔案中') || msg.includes('轉錄中') || msg.includes('進度')) {
    appendModalLog(msg);
    return;
  }
  
  if (msg.includes('等待') || msg.includes('傳送中') || msg.includes('上傳中')) return;
  
  // 顯示 Toast
  const container = document.getElementById('toast-container');
  if (!container) return;
  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  let icon = 'ℹ️';
  if (type === 'ok') icon = '✅';
  if (type === 'error') icon = '❌';
  toast.innerHTML = `<span>${icon}</span> <span>${msg.replace(/✅ |❌ |📋 |📤 |⚠️ /g, '')}</span>`;
  container.appendChild(toast);
  setTimeout(() => {
    if (toast.parentNode) toast.parentNode.removeChild(toast);
  }, 3000);
}

function escHtml(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
}

// ── Timer ────────────────────────────────────────────────────
function startTimer() {
  timerSec = 0
  const el = document.getElementById('timer')
  el.classList.add('active')
  timerInterval = setInterval(() => {
    timerSec++
    const m = String(Math.floor(timerSec/60)).padStart(2,'0')
    const s = String(timerSec % 60).padStart(2,'0')
    el.textContent = `${m}:${s}`
  }, 1000)
}
function stopTimer() {
  clearInterval(timerInterval)
  const el = document.getElementById('timer')
  el.classList.remove('active')
  el.textContent = ''
}

// ── Waveform ─────────────────────────────────────────────────
let animFrame = null
let analyser  = null

function startWaveform(stream) {
  const canvas = document.getElementById('waveform')
  canvas.classList.add('active')
  const ctx = canvas.getContext('2d')
  const audioCtx = new AudioContext()
  const src = audioCtx.createMediaStreamSource(stream)
  analyser = audioCtx.createAnalyser()
  analyser.fftSize = 256
  src.connect(analyser)

  const data = new Uint8Array(analyser.frequencyBinCount)

  function draw() {
    animFrame = requestAnimationFrame(draw)
    analyser.getByteTimeDomainData(data)

    canvas.width  = canvas.offsetWidth
    canvas.height = canvas.offsetHeight
    ctx.clearRect(0, 0, canvas.width, canvas.height)

    ctx.lineWidth   = 4
    ctx.lineCap     = 'round'
    
    // Add glowing gradient
    const gradient = ctx.createLinearGradient(0, 0, canvas.width, 0);
    gradient.addColorStop(0, '#7c6aff');
    gradient.addColorStop(0.5, '#a78bfa');
    gradient.addColorStop(1, '#34d399');
    ctx.strokeStyle = gradient;
    ctx.shadowBlur = 15;
    ctx.shadowColor = '#a78bfa';

    ctx.beginPath()

    const sliceW = canvas.width / data.length
    let x = 0
    for (let i = 0; i < data.length; i++) {
      const v = data[i] / 128
      const y = (v * canvas.height) / 2
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
      x += sliceW
    }
    ctx.stroke()
  }
  draw()
}

function stopWaveform() {
  cancelAnimationFrame(animFrame)
  const canvas = document.getElementById('waveform')
  canvas.classList.remove('active')
  const ctx = canvas.getContext('2d')
  ctx.clearRect(0, 0, canvas.width, canvas.height)
}
</script>
</body>
</html>
"""
