// ── Theme toggle ──────────────────────────────────────────────
function toggleTheme() {
  const body = document.body
  const isDark = body.dataset.theme === 'dark'
  const next = isDark ? 'light' : 'dark'
  body.dataset.theme = next
  const btn = document.getElementById('theme-btn')
  if (btn) btn.textContent = next === 'dark' ? '☀ Light' : '☾ Dark'
  try { localStorage.setItem('echo-theme', next) } catch(e) {}
}
function initTheme() {
  let saved
  try { saved = localStorage.getItem('echo-theme') } catch(e) {}
  const theme = saved || 'dark'
  document.body.dataset.theme = theme
  const btn = document.getElementById('theme-btn')
  if (btn) btn.textContent = theme === 'dark' ? '☀ Light' : '☾ Dark'
}

// ── Pill selector helpers ─────────────────────────────────────
function getPillValue(groupId) {
  return document.querySelector('#' + groupId + ' .pill.active')?.dataset.val || ''
}
function setPill(el, groupId) {
  document.querySelectorAll('#' + groupId + ' .pill').forEach(p => p.classList.remove('active'))
  el.classList.add('active')
  updateQBSummary()
}

// ── Quick bar collapse/expand ─────────────────────────────────
function updateQBSummary() {
  const modelVal = getPillValue('model-pill-group')
  const el = {
    model:  document.getElementById('qb-model'),
    lang:   document.getElementById('qb-lang'),
    mode:   document.getElementById('qb-mode'),
    domain: document.getElementById('qb-domain'),
  }
  const modeMap   = { standard: '標準', live: '即時', system: '系統音訊' }
  const domainMap = { general: '通用', media: '媒體', tech: '技術', medical: '醫療', legal: '法律' }
  const modeVal   = getPillValue('mode-pill-group')
  const domainVal = getPillValue('domain-pill-group')
  if (el.model)  el.model.textContent  = modelVal === 'large' ? 'large-v3' : modelVal
  if (el.lang)   el.lang.textContent   = getPillValue('lang-pill-group')
  if (el.mode)   el.mode.textContent   = modeMap[modeVal]   ?? modeVal
  if (el.domain) el.domain.textContent = domainMap[domainVal] ?? domainVal
}
function toggleQuickSettings() {
  document.getElementById('quick-bar')?.classList.toggle('expanded')
}

// ── Transcript tabs ───────────────────────────────────────────
function switchTab(tabName, btn) {
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'))
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'))
  if (btn) btn.classList.add('active')
  const panel = document.getElementById('panel-' + tabName)
  if (panel) panel.classList.add('active')
}

// ── 錯誤碼對照表（P0-5）──────────────────────────────────────
const ERROR_MESSAGES = {
  FFMPEG_MISSING:          'ffmpeg 未安裝。請執行 brew install ffmpeg，或重新執行 setup.sh',
  MODEL_LOAD_FAILED:       '模型載入失敗。請確認網路連線後重試，或重新執行 setup.sh',
  LLM_API_ERROR:           'LLM API 呼叫失敗。請至「LLM 設定」確認 API Key 是否正確',
  NO_AUDIO:                '未收到音訊，請確認麥克風已授權',
  EMPTY_TRANSCRIPT:        '未偵測到語音內容',
  BROKEN_PIPE:             '連線中斷，請重新錄音',
  TRANSCRIPTION_FAILED:    '轉錄失敗，請查看側邊欄 log 取得詳細資訊',
  SCREEN_RECORDING_DENIED: '⚠️ 螢幕錄製權限未授予 — 請前往「系統設定 → 隱私權與安全性 → 螢幕錄製」手動加入 Whisper STT，然後重新開啟 App',
}

// ── State ─────────────────────────────────────────────────────
let mediaRecorder    = null
let audioChunks      = []
let isRecording      = false
let timerInterval    = null
let timerSec         = 0
let lastText         = ''
let lastLang         = ''
let notionEnabled    = false
let _wakeLock        = null

// ── Chunked recording state ────────────────────────────────────
const CHUNK_INTERVAL_STANDARD = 10 * 60 * 1000  // 10 分鐘
const CHUNK_INTERVAL_LIVE     = 15 * 1000        // 15 秒
let _sessionId       = null
let _chunkIndex      = 0
let _chunkTimer      = null
let _pendingChunks   = 0   // 上傳中的段數，全部完成才算 done
let _webmHeader      = null  // 第一個 webm blob（含 EBML header）

function _genSessionId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 7)
}

async function _flushChunk(isLast = false) {
  if (audioChunks.length === 0) {
    // 沒有新音訊，但若已有 chunks 且這是最後一段，需通知 server 結束
    if (isLast && _chunkIndex > 0) {
      const form = new FormData()
      // 送一個空 blob（server 端會轉錄失敗但會觸發 all_done 判斷）
      // 改為：直接用 session finalize endpoint
      form.append('session_id',  _sessionId)
      form.append('chunk_index', _chunkIndex)
      form.append('is_last',     'true')
      form.append('mode',        getPillValue('mode-pill-group'))
      form.append('model',       getPillValue('model-pill-group'))
      form.append('language',    getPillValue('lang-pill-group'))
      form.append('domain',      getPillValue('domain-pill-group'))
      form.append('extra_terms', document.getElementById('extra-terms').value)
      form.append('obsidian',    obsidianEnabled ? 'true' : 'false')
      try {
        await fetch('/api/finish-session', { method: 'POST', body: form })
      } catch(e) {}
    }
    if (isLast) _onAllChunksUploaded()
    return
  }
  // chunk 1+ 需要在前面加上第一個 blob（含 WebM EBML header），否則 ffmpeg 無法解析
  const chunks = (_chunkIndex > 0 && _webmHeader !== null)
    ? [_webmHeader, ...audioChunks]
    : [...audioChunks]
  const blob  = new Blob(chunks, { type: 'audio/webm' })
  audioChunks = []   // 立刻清空，釋放記憶體
  const idx   = _chunkIndex++

  const form = new FormData()
  form.append('audio',       blob, `chunk_${idx}.webm`)
  form.append('session_id',  _sessionId)
  form.append('chunk_index', idx)
  form.append('is_last',     isLast ? 'true' : 'false')
  form.append('model',       getPillValue('model-pill-group'))
  form.append('language',    getPillValue('lang-pill-group'))
  form.append('domain',      getPillValue('domain-pill-group'))
  form.append('extra_terms', document.getElementById('extra-terms').value)
  form.append('obsidian',    obsidianEnabled ? 'true' : 'false')
  form.append('mode',        getPillValue('mode-pill-group'))

  _pendingChunks++
  try {
    const r = await fetch('/api/upload-chunk', { method: 'POST', body: form })
    if (!r.ok) {
      const d = await r.json().catch(() => ({}))
      setStatus(`❌ 上傳第 ${idx + 1} 段失敗：${d.error || '未知錯誤'}`, 'error')
    }
  } catch(e) {
    setStatus(`❌ 上傳第 ${idx + 1} 段失敗：${e.message}`, 'error')
  } finally {
    _pendingChunks--
    if (isLast && _pendingChunks === 0) _onAllChunksUploaded()
  }
}

function _onAllChunksUploaded() {
  // 所有段都已上傳，等 SSE done 事件由 server 觸發
}

function _fmtChunkTime(idx) {
  const start = idx * 10
  const end   = (idx + 1) * 10
  return `${start}:00 - ${end}:00`
}

async function _acquireWakeLock() {
  if (!('wakeLock' in navigator)) {
    setStatus('⚠️ 錄音中請勿讓螢幕休眠（此裝置不支援自動防休眠）', 'warn')
    return
  }
  try {
    _wakeLock = await navigator.wakeLock.request('screen')
    _wakeLock.addEventListener('release', () => {
      if (isRecording) setStatus('⚠️ 螢幕鎖定可能中斷錄音，請保持螢幕開啟', 'warn')
    })
  } catch(e) {
    setStatus('⚠️ 無法鎖定螢幕喚醒，長時間錄音請確認螢幕不會休眠', 'warn')
  }
}

function _releaseWakeLock() {
  if (_wakeLock) { _wakeLock.release(); _wakeLock = null }
}
let obsidianEnabled = false

// ── 分頁互斥鎖 ────────────────────────────────────────────────
const TAB_ID = Math.random().toString(36).slice(2)
const TAB_LOCK_KEY = 'whisper_recording_tab'
const _tabChannel = typeof BroadcastChannel !== 'undefined' ? new BroadcastChannel('whisper_tab') : null

function _acquireTabLock() {
  localStorage.setItem(TAB_LOCK_KEY, TAB_ID)
  _tabChannel?.postMessage({ type: 'recording_started', tabId: TAB_ID })
}
function _releaseTabLock() {
  if (localStorage.getItem(TAB_LOCK_KEY) === TAB_ID) {
    localStorage.removeItem(TAB_LOCK_KEY)
  }
  _tabChannel?.postMessage({ type: 'recording_stopped', tabId: TAB_ID })
}
function _isTabLocked() {
  const owner = localStorage.getItem(TAB_LOCK_KEY)
  return owner && owner !== TAB_ID
}

// 監聽其他分頁的廣播
if (_tabChannel) {
  _tabChannel.onmessage = e => {
    if (e.data.tabId === TAB_ID) return
    if (e.data.type === 'recording_started') {
      // 其他分頁開始錄音，鎖定本頁錄音按鈕
      _applyTabLockUI(true)
    } else if (e.data.type === 'recording_stopped') {
      _applyTabLockUI(false)
    }
  }
}

function _applyTabLockUI(locked) {
  const btn = document.getElementById('record-btn')
  const lbl = document.getElementById('btn-label')
  if (!btn) return
  if (locked) {
    btn.disabled = true
    btn.classList.add('processing')
    if (lbl) lbl.textContent = '其他分頁錄音中'
    setStatus('⚠️ 已有另一個分頁正在錄音，請關閉後使用此分頁', 'error')
  } else {
    btn.disabled = false
    btn.classList.remove('processing')
    if (lbl) lbl.textContent = '點擊開始錄音'
    setStatus('')
  }
}

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

// ── SSE reconnect recovery ────────────────────────────────────
async function _onSSEReconnected() {
  try {
    const r = await fetch('/api/last_transcript')
    const d = await r.json()
    if (d.ok && d.text) {
      if (!lastText) {
        // UI 是空的，補回結果
        addTranscript(d.text, d.language, d.time)
        _exportSegments = d.segments || []
        _syncExportBtn()
        saveToHistory(d.text, d.language, d.segments || [])
        setBtnState('idle')
        hideProcessingModal()
        setStatus('✅ 連線恢復，已補回轉錄結果', 'ok')
      } else {
        // UI 已有內容，只恢復 idle 狀態
        setBtnState('idle')
        hideProcessingModal()
        setStatus('✅ 伺服器連線恢復', 'ok')
      }
    } else {
      // 伺服器沒有暫存結果（可能重啟過），如果 UI 卡在進度就重置
      setBtnState('idle')
      hideProcessingModal()
      if (!lastText) setStatus('⚠️ 連線已恢復，轉錄結果不存在，請重新上傳', 'error')
      else setStatus('✅ 伺服器連線恢復', 'ok')
    }
  } catch(e) {}
}

// ── SSE ──────────────────────────────────────────────────────
let _sseConnected = false
let _sseEverConnected = false  // 第一次成功連線後才設為 true
let _sseReconnectTimer = null
let _sseRetryCount = 0
const _SSE_MAX_RETRY = 10
const _SSE_RETRY_DELAYS = [2, 3, 5, 8, 13, 21, 30, 30, 30, 30] // 秒，指數退避

function _showSSEBanner(show) {
  let banner = document.getElementById('sse-banner')
  if (!banner) {
    banner = document.createElement('div')
    banner.id = 'sse-banner'
    banner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:2000;background:rgba(239,68,68,0.9);color:#fff;text-align:center;padding:8px 16px;font-size:13px;backdrop-filter:blur(8px);transition:transform .3s;'
    document.body.prepend(banner)
  }
  if (show) {
    const retry = _SSE_RETRY_DELAYS[Math.min(_sseRetryCount, _SSE_MAX_RETRY - 1)]
    banner.textContent = `⚠️ 與伺服器的連線中斷，${retry} 秒後自動重連（第 ${_sseRetryCount + 1} 次）`
    banner.style.transform = 'translateY(0)'
  } else {
    banner.style.transform = 'translateY(-100%)'
  }
}

function _initSSE() {
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
  evtSrc.onopen = () => {
    const isReconnect = _sseEverConnected && !_sseConnected
    _sseConnected = true
    _sseEverConnected = true
    _sseRetryCount = 0
    if (_sseReconnectTimer) { clearTimeout(_sseReconnectTimer); _sseReconnectTimer = null }
    _showSSEBanner(false)
    if (isReconnect) _onSSEReconnected()
  }
  evtSrc.onerror = () => {
    if (!_sseConnected && _sseRetryCount === 0) return // 初次連線失敗靜默等待
    _sseConnected = false
    evtSrc.close()
    if (_sseRetryCount >= _SSE_MAX_RETRY) {
      setStatus('❌ 伺服器連線失敗，請重新整理頁面', 'error')
      _showSSEBanner(false)
      return
    }
    _showSSEBanner(true)
    const delay = (_SSE_RETRY_DELAYS[Math.min(_sseRetryCount, _SSE_RETRY_DELAYS.length - 1)]) * 1000
    _sseRetryCount++
    _sseReconnectTimer = setTimeout(() => _initSSE(), delay)
  }
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
  evtSrc.addEventListener('chunk_done', e => {
    const d = JSON.parse(e.data)
    if (!d.text) return
    const isLiveMode = d.live_mode === true
    // 標準模式單段：等 transcript 統一顯示
    if (!isLiveMode && d.chunk_total === 1) return
    const box = document.getElementById('transcript-box')
    const entry = document.createElement('div')
    entry.className = 'transcript-entry chunk-interim'
    const label = isLiveMode
      ? new Date().toTimeString().slice(0,8)
      : `第 ${d.chunk_index + 1}/${d.chunk_total} 段｜${_fmtChunkTime(d.chunk_index)}`
    entry.innerHTML = `<div class="transcript-time" contenteditable="false">${label}</div>
                       <div class="transcript-text">${escHtml(d.text)}</div>`
    box.appendChild(entry)
    box.scrollTop = box.scrollHeight
    lastText = Array.from(box.querySelectorAll('.transcript-text')).map(el => el.textContent).join('\n')
    syncUploadBtn()
  })
  evtSrc.addEventListener('done', async e => {
    const d = JSON.parse(e.data)
    setBtnState('idle')
    hideProcessingModal()
    if (!d.ok) {
      const msg = ERROR_MESSAGES[d.error_code] || d.error || '未知錯誤，請查看 log'
      if (d.error_code === 'EMPTY_TRANSCRIPT') setStatus('⚠️ 未偵測到語音內容', 'error')
      else if (d.error_code === 'SCREEN_RECORDING_DENIED') setStatus(msg, 'error')
      else setStatus(`❌ ${msg}`, 'error')
      syncUploadBtn()
      return
    }
    lastText = d.text
    lastLang = d.language
    // Fallback: if transcript event was missed, display result from done event
    const box = document.getElementById('transcript-box')
    if (d.text && box && box.querySelectorAll('.transcript-entry').length === 0) {
      const now = new Date().toTimeString().slice(0,8)
      addTranscript(d.text, d.language || '?', now)
    }
    syncUploadBtn()
    setStatus('✅ 轉錄完成', 'ok')
    if (notionEnabled && notionReady) {
      await doUpload(d.text, d.language)
    }
  })
  return evtSrc
}

_initSSE()

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

  // 頁面載入時檢查是否有其他分頁正在錄音
  if (_isTabLocked()) _applyTabLockUI(true)

  // 頁面載入時主動補領上次轉錄結果（應對電腦關機/伺服器重啟後重開頁面）
  if (!lastText) {
    try {
      const r = await fetch('/api/last_transcript')
      const d = await r.json()
      if (d.ok && d.text) {
        addTranscript(d.text, d.language, d.time)
        _exportSegments = d.segments || []
        _syncExportBtn()
        saveToHistory(d.text, d.language, d.segments || [])
        setStatus('📂 已還原上次轉錄結果', 'ok')
      }
    } catch(e) {}
  }
};

// 錄音中或轉錄中關閉/離開頁面時警告
window.addEventListener('beforeunload', e => {
  if (isRecording) {
    e.preventDefault()
    e.returnValue = '錄音尚未停止，關閉頁面將遺失錄音內容。'
    return e.returnValue
  }
  const modal = document.getElementById('processing-modal')
  if (modal && modal.classList.contains('active')) {
    e.preventDefault()
    e.returnValue = '轉錄正在進行中，關閉頁面後伺服器會繼續處理，重新開啟可補回結果。'
    return e.returnValue
  }
})

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


function toggleSavedDict() {
  const container = document.getElementById('vocab-tags-container')
  const title = document.getElementById('saved-dict-title')
  if (!container || !title) return
  const btn = document.getElementById('vocab-library-btn')
  const isOpen = container.style.display !== 'none'
  if (isOpen) {
    container.style.display = 'none'
    title.style.display = 'none'
    if (btn) btn.style.opacity = '0.5'
  } else {
    const lib = getVocabLibrary()
    if (lib.length === 0) {
      title.textContent = '詞庫目前沒有儲存詞彙'
      title.style.display = 'block'
      container.style.display = 'none'
    } else {
      title.style.display = 'none'
      container.style.display = 'block'
      renderVocabTags()
    }
    if (btn) btn.style.opacity = '1'
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
    _updateLlmKeyStatus(r.has_anthropic_key, r.has_openai_key)
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

// ── Mode change ───────────────────────────────────────────────
function onModeChange() {
  const mode = getPillValue('mode-pill-group')
  const hint = document.getElementById('system-audio-hint')
  const icon = document.getElementById('btn-icon')
  const lbl  = document.getElementById('btn-label')
  if (mode === 'system') {
    hint.style.display = 'block'
    icon.textContent = '🖥️'
    lbl.textContent  = 'SYS'
    if (!localStorage.getItem('system_audio_tip_shown')) {
      localStorage.setItem('system_audio_tip_shown', '1')
      showToast('💡 系統音訊需授權螢幕錄製：系統設定 → 隱私權 → 螢幕錄製 → 開啟 Whisper STT', 6000)
    }
  } else {
    hint.style.display = 'none'
    icon.textContent = '🎤'
    lbl.textContent  = 'REC'
  }
}

// ── System Audio ──────────────────────────────────────────────
let _sysAudioSessionId = null

async function startSystemAudio() {
  const model    = getPillValue('model-pill-group')
  const language = getPillValue('lang-pill-group')
  const domain   = getPillValue('domain-pill-group')
  const extra    = document.getElementById('extra-terms').value
  const withMic  = document.getElementById('mix-mic-toggle')?.checked ?? false
  const resp = await fetch('/api/system-audio/start', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ model, language, domain, extra_terms: extra, with_mic: withMic, save_obsidian: obsidianEnabled })
  })
  const data = await resp.json()
  if (!resp.ok) {
    setStatus('❌ 系統音訊啟動失敗：' + (data.error || resp.status), 'error')
    return false
  }
  _sysAudioSessionId = data.session_id
  return true
}

async function stopSystemAudio() {
  if (!_sysAudioSessionId) return
  await fetch('/api/system-audio/stop', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ session_id: _sysAudioSessionId })
  })
  _sysAudioSessionId = null
}

// ── Record ────────────────────────────────────────────────────
async function toggleRecord() {
  const mode = getPillValue('mode-pill-group')

  // System audio mode: simple toggle without mic / modal
  if (mode === 'system') {
    if (isRecording) {
      isRecording = false
      stopTimer()
      setRecordingUI(false)
      setStatus('⏳ 正在整合轉錄結果…')
      await stopSystemAudio()
    } else {
      const ok = await startSystemAudio()
      if (!ok) return
      isRecording = true
      startTimer()
      setRecordingUI(true)
      setStatus('🔴 擷取系統音訊中（每 15 秒自動轉錄）…')
    }
    return
  }

  if (isRecording) {
    // 錄音不足 3 秒 → 直接取消，不送出
    if (timerSec < 3) {
      cancelRecording()
      setStatus('⚠️ 錄音太短，已取消', 'error')
      return
    }
    // 顯示確認 modal
    const m = document.getElementById('stop-confirm-modal')
    const mins = Math.floor(timerSec / 60)
    const secs = timerSec % 60
    document.getElementById('stop-confirm-duration').textContent =
      `已錄製 ${mins > 0 ? mins + ' 分 ' : ''}${secs} 秒，停止後將立即送出轉錄。`
    m.classList.add('active')
  } else {
    await startRecording()
  }
}

function confirmStop(doStop) {
  document.getElementById('stop-confirm-modal').classList.remove('active')
  if (doStop) stopRecording()
}

function cancelRecording() {
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    mediaRecorder.ondataavailable = null
    mediaRecorder.onstop = null
    mediaRecorder.stop()
    mediaRecorder.stream?.getTracks().forEach(t => t.stop())
  }
  isRecording = false
  audioChunks = []
  stopTimer()
  stopWaveform()
  setRecordingUI(false)
  _releaseTabLock()
}

async function startRecording() {
  if (_isTabLocked()) {
    setStatus('⚠️ 已有另一個分頁正在錄音，請先關閉該分頁', 'error')
    return
  }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    audioChunks   = []
    _webmHeader   = null
    _sessionId    = _genSessionId()
    _chunkIndex   = 0
    _pendingChunks = 0
    // 重置 player，避免舊的 Error 狀態殘留
    const _player = document.getElementById('local-audio-player')
    _player.src   = ''
    _player.style.display = 'none'
    const _mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
      ? 'audio/webm;codecs=opus'
      : MediaRecorder.isTypeSupported('audio/mp4')
        ? 'audio/mp4'
        : ''
    mediaRecorder = _mimeType ? new MediaRecorder(stream, { mimeType: _mimeType }) : new MediaRecorder(stream)
    mediaRecorder.ondataavailable = e => {
      if (e.data.size > 0) {
        if (_webmHeader === null) _webmHeader = e.data  // 第一個 blob 含 EBML header
        audioChunks.push(e.data)
      }
    }
    mediaRecorder.onstop = async () => {
      stream.getTracks().forEach(t => t.stop())
      // 上傳最後一段（可能是唯一一段）
      if (audioChunks.length === 0 && _chunkIndex === 0) {
        setStatus('⚠️ 錄音內容為空，請重試', 'error')
        setBtnState('idle')
        return
      }
      // 建立預覽播放器（即時模式因時間軸不連續無法正常播放，略過）
      const player = document.getElementById('local-audio-player')
      const _isLiveMode = getPillValue('mode-pill-group') === 'live'
      if (!_isLiveMode && audioChunks.length > 0) {
        const actualType = mediaRecorder.mimeType || 'audio/webm'
        const previewBlob = new Blob([...audioChunks], { type: actualType })
        const previewURL  = URL.createObjectURL(previewBlob)
        player.onerror = () => { player.style.display = 'none'; URL.revokeObjectURL(previewURL) }
        player.src = previewURL
        player.style.display = 'block'
      } else {
        player.src = ''
        player.style.display = 'none'
      }
      await _flushChunk(true)
    }
    // 每 10 分鐘自動切段
    const isLive = getPillValue('mode-pill-group') === 'live'
    const chunkMs = isLive ? CHUNK_INTERVAL_LIVE : CHUNK_INTERVAL_STANDARD
    _chunkTimer = setInterval(() => _flushChunk(false), chunkMs)
    mediaRecorder.start(100)

    _acquireTabLock()
    await _acquireWakeLock()
    isRecording = true
    startWaveform(stream)
    startTimer()
    setRecordingUI(true)
    const modeLabel = isLive ? '即時模式' : '標準模式'
    setStatus(`🔴 錄音中（${modeLabel}）…按下停止以轉錄`)
  } catch(e) {
    setStatus(`❌ 無法存取麥克風：${e.message}`, 'error')
  }
}

function stopRecording() {
  isRecording = false
  if (_chunkTimer) { clearInterval(_chunkTimer); _chunkTimer = null }
  stopTimer()
  stopWaveform()
  setRecordingUI(false)
  setStatus('⏳ 處理中…')
  _releaseTabLock()
  _releaseWakeLock()

  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    mediaRecorder.stop()  // onstop 已在 startRecording 設好，會自動送出
  }
}

async function sendAudio(stream) {
  stream?.getTracks().forEach(t => t.stop())
  const blob = new Blob(audioChunks, { type: 'audio/webm' })
  await uploadFileBlob(blob, 'recording.webm')
}

async function uploadFileBlob(blob, filename='upload.webm') {
  const form = new FormData()
  form.append('audio', blob, filename)
  form.append('model', getPillValue('model-pill-group'))
  form.append('language', getPillValue('lang-pill-group'))
  form.append('domain', getPillValue('domain-pill-group'))
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

  const files = Array.from(e.dataTransfer.files).filter(
    f => f.type.startsWith('audio/') || f.type.startsWith('video/')
  );
  if (files.length === 0) {
    setStatus('❌ 請拖曳音訊或影片檔案', 'error');
    return;
  }
  if (files.length === 1) {
    const player = document.getElementById('local-audio-player');
    player.src = URL.createObjectURL(files[0]);
    player.style.display = 'block';
    audioChunks = [files[0]];
    uploadFileBlob(files[0], files[0].name);
  } else {
    batchTranscribe(files);
  }
});

async function batchTranscribe(files) {
  let failed = 0;
  setBtnState('processing');
  for (let i = 0; i < files.length; i++) {
    setStatus(`📦 批次轉錄 ${i + 1}/${files.length}：${files[i].name}`, 'info');
    try {
      await uploadFileBlob(files[i], files[i].name);
    } catch (_) {
      failed++;
    }
  }
  setBtnState('idle');
  syncUploadBtn();
  if (failed === 0) {
    setStatus(`✅ 批次完成，共 ${files.length} 個檔案`, 'done');
  } else {
    setStatus(`⚠️ 批次完成：${files.length - failed} 成功，${failed} 失敗`, 'error');
  }
}

// done 事件已移入 _initSSE()，確保重連後仍有效

// ── Keyboard shortcuts ────────────────────────────────────────
// Space = 切換錄音；Cmd+U = 開啟檔案選擇；Cmd+S = 存 Notion
document.addEventListener('keydown', (e) => {
  const tag = document.activeElement?.tagName?.toLowerCase();
  const isInput = tag === 'input' || tag === 'textarea' || tag === 'select';
  if (isInput) return;

  if (e.code === 'Space' && !e.metaKey && !e.ctrlKey && !e.altKey) {
    e.preventDefault();
    toggleRecord();
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key === 'u') {
    e.preventDefault();
    document.getElementById('file-input')?.click();
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key === 's') {
    e.preventDefault();
    uploadToNotion();
  }
});

// file-input change → 支援批次選擇
document.getElementById('file-input')?.addEventListener('change', (e) => {
  const files = Array.from(e.target.files).filter(
    f => f.type.startsWith('audio/') || f.type.startsWith('video/')
  );
  e.target.value = '';
  if (files.length === 0) return;
  if (files.length === 1) {
    const player = document.getElementById('local-audio-player');
    player.src = URL.createObjectURL(files[0]);
    player.style.display = 'block';
    audioChunks = [files[0]];
    uploadFileBlob(files[0], files[0].name);
  } else {
    batchTranscribe(files);
  }
});

// ── Upload ────────────────────────────────────────────────────
async function uploadToNotion() {
  if (!lastText) return
  await doUpload(lastText, lastLang)
}

async function doUpload(text, lang) {
  const pageId = null  // 使用偏好設定中儲存的預設頁面
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
  // 清除分段的暫存條目，換成最終合併結果
  box.querySelectorAll('.chunk-interim').forEach(el => el.remove())
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
  // Use only .transcript-text elements to exclude timestamp/language labels
  const entries = Array.from(document.getElementById('transcript-box').querySelectorAll('.transcript-text'))
  const text = entries.length ? entries.map(el => el.textContent).join('\n').trim() : lastText.trim()
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
  statusEl.style.color = 'var(--muted)'
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

async function saveLlmKeys() {
  const anthropicKey = document.getElementById('anthropic-key').value.trim()
  const openaiKey    = document.getElementById('openai-key').value.trim()
  const statusEl     = document.getElementById('llm-save-status')

  if (!anthropicKey && !openaiKey) {
    statusEl.textContent = '⚠️ 請至少填寫一個 Key'
    statusEl.style.color = 'var(--yellow, #f59e0b)'
    return
  }
  // 格式簡易驗證
  if (anthropicKey && !anthropicKey.startsWith('sk-ant-')) {
    statusEl.textContent = '⚠️ Claude Key 格式不正確（應以 sk-ant- 開頭）'
    statusEl.style.color = 'var(--red)'
    return
  }
  if (openaiKey && !openaiKey.startsWith('sk-')) {
    statusEl.textContent = '⚠️ OpenAI Key 格式不正確（應以 sk- 開頭）'
    statusEl.style.color = 'var(--red)'
    return
  }

  statusEl.textContent = '儲存中…'
  statusEl.style.color = 'var(--muted)'
  try {
    const r = await fetch('/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ anthropic_key: anthropicKey, openai_key: openaiKey }),
    })
    const d = await r.json()
    if (!r.ok) throw new Error(d.error)
    document.getElementById('anthropic-key').value = ''
    document.getElementById('openai-key').value = ''
    statusEl.textContent = '✅ 已儲存'
    statusEl.style.color = 'var(--green)'
    _updateLlmKeyStatus(d.has_anthropic_key, d.has_openai_key)
    setTimeout(() => { statusEl.textContent = '' }, 3000)
  } catch(e) {
    statusEl.textContent = `❌ ${e.message}`
    statusEl.style.color = 'var(--red)'
  }
}

function _updateLlmKeyStatus(hasAnthropic, hasOpenai) {
  const aEl = document.getElementById('anthropic-key-status')
  const oEl = document.getElementById('openai-key-status')
  if (aEl) aEl.textContent = hasAnthropic ? '✓ 已設定' : ''
  if (oEl) oEl.textContent = hasOpenai    ? '✓ 已設定' : ''
}

// ── 模型下載偵測（P0-2）──────────────────────────────────────
let _modelPollTimer = null

async function checkModelReady(modelName) {
  const overlay = document.getElementById('model-download-overlay')
  try {
    const r = await fetch(`/api/model-status?model=${encodeURIComponent(modelName)}`)
    const d = await r.json()
    if (d.cached) {
      overlay.style.display = 'none'
      if (_modelPollTimer) { clearInterval(_modelPollTimer); _modelPollTimer = null }
      return true
    }
    // 未快取 → 顯示 overlay 並觸發下載
    document.getElementById('model-dl-model-name').textContent =
      `模型：${modelName}（首次下載約 100–500 MB，之後離線也可使用）`
    overlay.style.display = 'flex'

    if (d.state !== 'downloading') {
      await fetch('/api/warmup-model', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: modelName }),
      })
    }
    // 偽進度動畫（無法取得真實百分比，讓用戶知道在下載）
    let pct = parseInt(document.getElementById('model-dl-bar').style.width) || 0
    if (pct < 90) {
      pct = Math.min(pct + 3, 90)
      document.getElementById('model-dl-bar').style.width = pct + '%'
    }
    document.getElementById('model-dl-status').textContent =
      d.state === 'error' ? '❌ 下載失敗，請確認網路後重新整理頁面' : '正在下載，請保持網路連線…'
    return false
  } catch(e) {
    return true // 無法連線就不擋錄音
  }
}

// ── UI helpers ────────────────────────────────────────────────
function setRecordingUI(recording) {
  const btn   = document.getElementById('record-btn')
  const icon  = document.getElementById('btn-icon')
  const label = document.getElementById('btn-label')
  const wrap  = document.getElementById('rec-rings-wrap')
  const sb    = document.getElementById('status-bar')
  if (recording) {
    btn.className   = 'recording'
    if (wrap) wrap.classList.add('recording')
    icon.textContent  = '⏹'
    label.textContent = 'STOP'
    if (sb) { sb.textContent = 'REC ●'; sb.className = 'error'; }
  } else {
    btn.className   = ''
    if (wrap) wrap.classList.remove('recording')
    icon.textContent  = '🎤'
    label.textContent = 'REC'
    if (sb) { sb.textContent = 'STANDBY_'; sb.className = ''; }
  }
}

function setBtnState(state) {
  const btn   = document.getElementById('record-btn')
  const icon  = document.getElementById('btn-icon')
  const label = document.getElementById('btn-label')
  const wrap  = document.getElementById('rec-rings-wrap')
  const sb    = document.getElementById('status-bar')
  if (state === 'processing') {
    btn.className   = 'processing'
    if (wrap) wrap.classList.remove('recording')
    icon.textContent  = '⏳'
    label.textContent = 'AI'
    if (sb) { sb.textContent = 'PROCESSING_'; sb.className = 'warn'; }
    showProcessingModal()
  } else {
    btn.className   = ''
    if (wrap) wrap.classList.remove('recording')
    icon.textContent  = '🎤'
    label.textContent = 'REC'
    if (sb) { sb.textContent = 'STANDBY_'; sb.className = ''; }
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

// ── 頁面初始化 ────────────────────────────────────────────────
async function _initModelCheck() {
  const modelName = getPillValue('model-pill-group')
  const ready = await checkModelReady(modelName)
  if (!ready) {
    // 每 3 秒輪詢，直到模型就緒
    _modelPollTimer = setInterval(async () => {
      const r = await checkModelReady(modelName)
      if (r && _modelPollTimer) {
        clearInterval(_modelPollTimer)
        _modelPollTimer = null
      }
    }, 3000)
  }
}

async function _checkConfigHealth() {
  try {
    const r = await fetch('/api/config/health')
    if (!r.ok) return
    const data = await r.json()

    // TCC 權限警示（優先顯示，不受 localStorage 限制）
    if (data.permissions) {
      if (data.permissions.screen_recording === 'denied') {
        appendStatus('⚠️ 螢幕錄製權限未授予，系統音訊功能不可用（系統設定 → 隱私權 → 螢幕錄製）')
      }
      if (data.permissions.microphone === 'denied') {
        appendStatus('⚠️ 麥克風權限未授予，錄音功能不可用')
      }
    }

    // 設定缺漏：只在首次啟動時顯示引導 modal
    if (!data.ok && data.missing && data.missing.length > 0) {
      const shownKey = 'onboarding_shown_v2'
      if (!localStorage.getItem(shownKey)) {
        const list = document.getElementById('onboarding-list')
        if (list) {
          list.innerHTML = data.missing.map(m =>
            `<li style="display:flex;align-items:center;gap:8px;font-size:13px;">
              <span style="color:var(--accent)">⚠️</span>
              <span><strong>${m.feature}</strong> — 未設定 ${m.key}</span>
            </li>`
          ).join('')
          document.getElementById('onboarding-modal').style.display = 'flex'
          localStorage.setItem(shownKey, '1')
        }
      }
    }
  } catch (_) {}
}

function openPreferences() {
  document.getElementById('onboarding-modal').style.display = 'none'
  if (window.pywebview && window.pywebview.api) {
    window.pywebview.api.open_preferences()
  } else {
    // dev server fallback：直接開新分頁
    window.open('/preferences', '_blank', 'width=560,height=620')
  }
}

document.addEventListener('DOMContentLoaded', () => {
  initTheme()
  updateQBSummary()
  _initModelCheck()
  _checkConfigHealth()
  // 切換模型時重新檢查
  document.getElementById('model-pill-group')?.addEventListener('click', e => {
    if (e.target.closest('.pill')) {
      if (_modelPollTimer) { clearInterval(_modelPollTimer); _modelPollTimer = null }
      _initModelCheck()
    }
  })
})
