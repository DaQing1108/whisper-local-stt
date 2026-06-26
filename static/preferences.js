async function _loadConfig() {
  try {
    const r = await fetch('/config')
    if (!r.ok) return
    const d = await r.json()
    if (d.obsidian_path) document.getElementById('obsidian-path').value = d.obsidian_path
    if (d.page_id_preview) document.getElementById('notion-page-id').placeholder = d.page_id_preview
    _setKeyStatus('anthropic-status', d.has_anthropic_key)
    _setKeyStatus('openai-status', d.has_openai_key)
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
    } else {
      _setStatus(statusEl, `✗ ${d.error || '儲存失敗'}`, false)
    }
  } catch (e) {
    _setStatus(statusEl, '✗ 儲存失敗', false)
  }
}

function _setStatus(el, msg, ok) {
  el.textContent = msg
  el.className = (el.classList.contains('save-status') ? 'save-status' : 'validate-status') + (ok ? ' ok' : ' err')
}

document.addEventListener('DOMContentLoaded', _loadConfig)
