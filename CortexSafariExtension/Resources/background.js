// background.js — Cortex Safari Extension Service Worker
//
// Orchestrates the capture flow:
//   1. Popup sends { action: 'capture_page', tabId, tabUrl, tabTitle }
//   2. If on a platform page, request DOM content from content.js
//   3. Send full payload to native app via SafariWebExtensionHandler (native messaging)
//   4. If native app unavailable, queue locally and retry on next popup open

'use strict';

// ── Native App ID ─────────────────────────────────────────────────────────
const NATIVE_APP_ID = 'io.bdcllc.cortex';

// ── Message Router ────────────────────────────────────────────────────────

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  switch (message.action) {
    case 'capture_page':
      handleCapture(message)
        .then(result => sendResponse({ success: true, result }))
        .catch(err   => sendResponse({ success: false, error: err.message }));
      return true; // Keep channel open for async response

    case 'flush_queue':
      flushPendingQueue()
        .then(count => sendResponse({ flushed: count }))
        .catch(() => sendResponse({ flushed: 0 }));
      return true;

    default:
      return false;
  }
});

// ── Capture Handler ───────────────────────────────────────────────────────

async function handleCapture({ tabId, tabUrl, tabTitle }) {
  if (!tabUrl || !tabUrl.startsWith('http')) {
    throw new Error('Cannot capture this page (non-HTTP URL)');
  }

  const host = (() => {
    try { return new URL(tabUrl).hostname.toLowerCase(); }
    catch { return ''; }
  })();

  const isPlatformPage =
    host.includes('twitter.com') ||
    host.includes('x.com')       ||
    host.includes('reddit.com');

  // Try to get platform content from content script
  let platformContent = null;
  if (isPlatformPage) {
    try {
      const response = await browser.tabs.sendMessage(tabId, { action: 'extract_content' });
      if (response?.success && response.content) {
        platformContent = response.content;
      }
    } catch {
      // Content script not available or page doesn't support it — fall through
      console.log('[Cortex] Content script unavailable, using basic capture');
    }
  }

  const payload = {
    action: 'capture',
    url: tabUrl,
    title: tabTitle || platformContent?.pageTitle || tabTitle,
    platformContent,
    capturedAt: new Date().toISOString(),
  };

  // Attempt native messaging → SafariWebExtensionHandler
  try {
    const nativeResponse = await browser.runtime.sendNativeMessage(NATIVE_APP_ID, payload);
    // Also flush any previously queued items
    await flushPendingQueue();
    return nativeResponse;
  } catch (nativeError) {
    console.warn('[Cortex] Native messaging failed — queueing for later:', nativeError.message);
    await enqueue(payload);
    throw new Error('Cortex app is not running. Item saved — will sync when app opens.');
  }
}

// ── Local Queue (fallback when app not running) ───────────────────────────

async function enqueue(payload) {
  const { pendingCaptures = [] } = await browser.storage.local.get('pendingCaptures');
  pendingCaptures.push({ ...payload, queuedAt: new Date().toISOString() });
  // Cap queue at 100 items to avoid unbounded storage growth
  const trimmed = pendingCaptures.slice(-100);
  await browser.storage.local.set({ pendingCaptures: trimmed });
}

async function flushPendingQueue() {
  const { pendingCaptures = [] } = await browser.storage.local.get('pendingCaptures');
  if (!pendingCaptures.length) return 0;

  let flushed = 0;
  const remaining = [];

  for (const item of pendingCaptures) {
    try {
      await browser.runtime.sendNativeMessage(NATIVE_APP_ID, item);
      flushed++;
    } catch {
      remaining.push(item); // Keep items that still can't be sent
    }
  }

  await browser.storage.local.set({ pendingCaptures: remaining });
  return flushed;
}

// ── Startup: flush any pending queue ─────────────────────────────────────
// Runs when service worker starts (app was relaunched or extension was reloaded)
flushPendingQueue().catch(() => {});
