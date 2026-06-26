const PRESETS = {
  meeting:   { desc: '標點、斷句、繁體中文會議記錄格式', prompt: '' },
  interview: { desc: '訪談逐字稿，保留語氣詞，自然分段', prompt: '你是繁體中文訪談逐字稿的標點專家。請在保持原文不變的前提下加入適當標點符號，保留「嗯」「啊」等語氣詞，每個問答自然分段。只輸出修正後的文字。' },
  tech:      { desc: '技術討論，保留英文術語與縮寫', prompt: '你是繁體中文技術會議記錄的標點專家。請加入適當標點符號，保留所有英文技術術語、縮寫與程式碼片段不得翻譯或修改。只輸出修正後的文字。' },
  custom:    { desc: '使用下方自訂 Prompt', prompt: null },
}

function selectPreset(btn) {
  document.querySelectorAll('.preset-pill').forEach(p => p.classList.remove('active'))
  btn.classList.add('active')
  const key = btn.dataset.preset
  const info = PRESETS[key]
  document.getElementById('preset-desc').textContent = info.desc
  document.getElementById('custom-prompt-field').style.display = key === 'custom' ? '' : 'none'
}

function _getActivePreset() {
  const active = document.querySelector('.preset-pill.active')
  return active ? active.dataset.preset : 'meeting'
}

async function _loadConfig() {
  try {
    const r = await fetch('/config')
    if (!r.ok) return
    const d = await r.json()
    if (d.obsidian_path) document.getElementById('obsidian-path').value = d.obsidian_path
    if (d.page_id_preview) document.getElementById('notion-page-id').placeholder = d.page_id_preview
    _setKeyStatus('anthropic-status', d.has_anthropic_key)
    _setKeyStatus('openai-status', d.has_openai_key)
    const promptEl = document.getElementById('llm-prompt')
    if (promptEl && d.llm_prompt !== undefined) promptEl.value = d.llm_prompt
    _setKeyStatus('hf-status', d.has_hf_token)
    if (d.llm_preset) {
      const btn = document.querySelector(`.preset-pill[data-preset="${d.llm_preset}"]`)
      if (btn) selectPreset(btn)
    }
    _loadUpdateStatus()
  } catch (_) {}
}

function _setKeyStatus(id, has) {
  const el = document.getElementById(id)
  if (!el) return
  el.textContent = has ? '✓ 已設定' : ''
  el.className = 'key-status' + (has ? ' ok' : '')
}

async function validateObsidian() {
  const path = document.getElementById('obsidian-path').value.trim()
  const statusEl = document.getElementById('obsidian-status')
  if (!path) { _setStatus(statusEl, '請輸入路徑', false); return }

  const btn = document.getElementById('validate-obsidian-btn')
  btn.disabled = true
  btn.textContent = '驗證中…'

  try {
    const r = await fetch('/api/validate-obsidian-path', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path })
    })
    const d = await r.json()
    _setStatus(statusEl, d.ok ? `✓ 路徑存在` : `✗ ${d.error || '路徑不存在'}`, d.ok)
  } catch (e) {
    _setStatus(statusEl, '✗ 驗證失敗', false)
  } finally {
    btn.disabled = false
    btn.textContent = '驗證'
  }
}

async function validateNotion() {
  const token  = document.getElementById('notion-token').value.trim()
  const pageId = document.getElementById('notion-page-id').value.trim()
  const statusEl = document.getElementById('notion-status')

  if (!token || !pageId) {
    _setStatus(statusEl, '請同時填寫 Token 與頁面 ID', false)
    return
  }

  const btn = document.getElementById('validate-notion-btn')
  btn.disabled = true
  btn.textContent = '驗證中…'

  try {
    const r = await fetch('/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token, page_id: pageId })
    })
    const d = await r.json()
    if (d.ok) {
      _setStatus(statusEl, `✓ 連線成功：${d.page_label || pageId}`, true)
    } else {
      _setStatus(statusEl, `✗ ${d.error || '連線失敗'}`, false)
    }
  } catch (e) {
    _setStatus(statusEl, '✗ 驗證失敗', false)
  } finally {
    btn.disabled = false
    btn.textContent = '驗證'
  }
}

async function saveAll() {
  const statusEl = document.getElementById('save-status')
  const payload = {
    obsidian_path:  document.getElementById('obsidian-path').value.trim(),
    token:          document.getElementById('notion-token').value.trim(),
    page_id:        document.getElementById('notion-page-id').value.trim(),
    anthropic_key:  document.getElementById('anthropic-key').value.trim(),
    openai_key:     document.getElementById('openai-key').value.trim(),
    hf_token:       document.getElementById('hf-token')?.value.trim() ?? '',
    llm_preset:     _getActivePreset(),
    llm_prompt:     _getActivePreset() === 'custom'
                      ? (document.getElementById('llm-prompt')?.value ?? '')
                      : (PRESETS[_getActivePreset()]?.prompt ?? ''),
  }

  statusEl.textContent = '儲存中…'
  statusEl.className = 'save-status'

  try {
    const r = await fetch('/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    })
    const d = await r.json()
    if (d.ok) {
      _setStatus(statusEl, '✓ 已儲存', true)
      _setKeyStatus('anthropic-status', d.has_anthropic_key)
      _setKeyStatus('openai-status', d.has_openai_key)
      _setKeyStatus('hf-status', d.has_hf_token)
    } else {
      _setStatus(statusEl, `✗ ${d.error || '儲存失敗'}`, false)
    }
  } catch (e) {
    _setStatus(statusEl, '✗ 儲存失敗', false)
  }
}

async function _loadUpdateStatus() {
  const statusEl = document.getElementById('updates-status')
  if (!statusEl) return
  try {
    const r = await fetch('/api/updates/status')
    const d = await r.json()
    _setStatus(statusEl, d.available ? '✓ Sparkle 已啟用' : `⚠ ${d.error || 'Sparkle 尚未啟用'}`, d.available)
  } catch (e) {
    _setStatus(statusEl, '⚠ 無法讀取更新狀態', false)
  }
}

async function checkForUpdates() {
  const statusEl = document.getElementById('updates-status')
  const btn = document.getElementById('check-updates-btn')
  btn.disabled = true
  btn.textContent = '檢查中…'
  _setStatus(statusEl, '正在開啟 Sparkle…', true)

  try {
    const r = await fetch('/api/updates/check', { method: 'POST' })
    const d = await r.json()
    if (r.ok && d.ok) {
      _setStatus(statusEl, '✓ 已開啟更新檢查', true)
    } else {
      _setStatus(statusEl, `⚠ ${d.error || 'Sparkle 尚未啟用'}`, false)
    }
  } catch (e) {
    _setStatus(statusEl, '⚠ 檢查更新失敗', false)
  } finally {
    btn.disabled = false
    btn.textContent = '檢查更新'
  }
}

async function checkDiarize() {
  const btn = document.getElementById('check-diarize-btn')
  const statusEl = document.getElementById('diarize-status')
  btn.disabled = true; btn.textContent = '檢查中…'
  try {
    const r = await fetch('/api/diarize/status')
    const d = await r.json()
    _setStatus(statusEl, d.available ? '✓ 說話者分離就緒' : '⚠ 未啟用：請填入 HF Token', d.available)
  } catch (e) {
    _setStatus(statusEl, '✗ 無法連線', false)
  } finally {
    btn.disabled = false; btn.textContent = '檢查狀態'
  }
}

function _setStatus(el, msg, ok) {
  el.textContent = msg
  el.className = (el.classList.contains('save-status') ? 'save-status' : 'validate-status') + (ok ? ' ok' : ' err')
}

function toggleTheme() {
  const body = document.body
  const next = body.dataset.theme === 'dark' ? 'light' : 'dark'
  body.dataset.theme = next
  const btn = document.getElementById('pref-theme-btn')
  if (btn) btn.textContent = next === 'dark' ? '☀ Light' : '☾ Dark'
  try { localStorage.setItem('echo-theme', next) } catch(e) {}
}
function _initPrefTheme() {
  let saved; try { saved = localStorage.getItem('echo-theme') } catch(e) {}
  const theme = saved || 'dark'
  document.body.dataset.theme = theme
  const btn = document.getElementById('pref-theme-btn')
  if (btn) btn.textContent = theme === 'dark' ? '☀ Light' : '☾ Dark'
}

document.addEventListener('DOMContentLoaded', () => { _initPrefTheme(); _loadConfig() })
