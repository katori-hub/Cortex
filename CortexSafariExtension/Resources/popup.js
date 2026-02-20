// popup.js — Cortex Safari Extension Popup
// Handles the extension toolbar popup UI.

'use strict';

document.addEventListener('DOMContentLoaded', async () => {

  const captureBtn    = document.getElementById('capture-btn');
  const urlPreview    = document.getElementById('url-preview');
  const messageEl     = document.getElementById('message');
  const platformBadge = document.getElementById('platform-badge');
  const contentBanner = document.getElementById('content-banner');
  const queueNotice   = document.getElementById('queue-notice');

  // ── Get current tab ──────────────────────────────────────────────────────

  let tab;
  try {
    [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  } catch {
    showMessage('Could not read current tab', 'error');
    captureBtn.disabled = true;
    return;
  }

  if (!tab?.url?.startsWith('http')) {
    urlPreview.textContent = tab?.url || '(no URL)';
    showMessage('This page cannot be saved to Cortex', 'error');
    captureBtn.disabled = true;
    return;
  }

  urlPreview.textContent = tab.url;

  // ── Platform detection ───────────────────────────────────────────────────

  const host = (() => {
    try { return new URL(tab.url).hostname.toLowerCase(); }
    catch { return ''; }
  })();

  const platformLabels = {
    'twitter.com': 'Twitter/X',
    'x.com':       'Twitter/X',
    'reddit.com':  'Reddit',
    'youtube.com': 'YouTube',
    'youtu.be':    'YouTube',
  };

  for (const [domain, label] of Object.entries(platformLabels)) {
    if (host.includes(domain)) {
      platformBadge.textContent = label;
      platformBadge.style.display = 'inline-block';
      // Show content detection banner for scraping targets
      if (domain !== 'youtube.com' && domain !== 'youtu.be') {
        contentBanner.classList.add('visible');
      }
      break;
    }
  }

  // ── Pending queue notice ─────────────────────────────────────────────────

  try {
    const { pendingCaptures = [] } = await browser.storage.local.get('pendingCaptures');
    if (pendingCaptures.length > 0) {
      queueNotice.textContent = `${pendingCaptures.length} item${pendingCaptures.length > 1 ? 's' : ''} queued (waiting for Cortex app)`;
      queueNotice.style.display = 'block';
    }
  } catch { /* non-fatal */ }

  // ── Capture ──────────────────────────────────────────────────────────────

  captureBtn.addEventListener('click', async () => {
    captureBtn.disabled = true;
    captureBtn.textContent = 'Saving…';
    clearMessage();

    try {
      const response = await browser.runtime.sendMessage({
        action: 'capture_page',
        tabId:  tab.id,
        tabUrl: tab.url,
        tabTitle: tab.title,
      });

      if (response?.success) {
        captureBtn.textContent = '✓ Saved';
        showMessage('Saved to Cortex', 'success');
        // Close popup after a brief confirmation
        setTimeout(() => window.close(), 1200);
      } else {
        const msg = response?.error || 'Unknown error';
        // Distinguish "app not running" (queued) from hard errors
        if (msg.includes('not running') || msg.includes('queued')) {
          captureBtn.textContent = 'Queued';
          showMessage(msg, 'pending');
        } else {
          captureBtn.textContent = 'Save to Cortex';
          captureBtn.disabled = false;
          showMessage(msg, 'error');
        }
      }
    } catch (err) {
      captureBtn.textContent = 'Save to Cortex';
      captureBtn.disabled = false;
      showMessage('Extension error: ' + err.message, 'error');
    }
  });

  // ── Helpers ──────────────────────────────────────────────────────────────

  function showMessage(text, type) {
    messageEl.textContent = text;
    messageEl.className = `message ${type}`;
  }

  function clearMessage() {
    messageEl.className = 'message';
    messageEl.textContent = '';
  }

});
