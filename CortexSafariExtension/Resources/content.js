// content.js — Cortex Safari Extension
// Platform-specific DOM scraping for Twitter/X and Reddit.
// Injected automatically on those domains by the manifest.
// Responds to messages from background.js requesting content extraction.

(function () {
  'use strict';

  // ── Platform Detection ────────────────────────────────────────────────────

  const host = window.location.hostname.toLowerCase();

  function detectPlatform() {
    if (host.includes('twitter.com') || host.includes('x.com')) return 'twitter';
    if (host.includes('reddit.com')) return 'reddit';
    return null;
  }

  const platform = detectPlatform();

  // ── Twitter / X Extraction ────────────────────────────────────────────────

  function extractTwitter() {
    // Handles both individual tweet pages and timeline views.
    // Targets the first (primary) tweet article on the page.

    const articles = document.querySelectorAll('article[data-testid="tweet"]');
    if (!articles.length) return null;

    const primary = articles[0];

    // Tweet text
    const tweetText = primary
      .querySelector('[data-testid="tweetText"]')
      ?.innerText?.trim() ?? '';

    // Author info — Twitter renders name + handle inside a single element
    const authorBlock = primary.querySelector('[data-testid="User-Name"]');
    const authorName   = authorBlock?.querySelector('span')?.innerText?.trim() ?? '';
    const authorHandle = authorBlock
      ?.querySelector('a[href*="/"]')
      ?.href?.split('/').filter(Boolean).pop() ?? '';

    // Timestamp
    const timestamp = primary.querySelector('time')?.getAttribute('datetime') ?? '';

    // Media URLs (images only — video URLs are not easily extractable from DOM)
    const mediaUrls = Array.from(
      primary.querySelectorAll('img[src*="pbs.twimg.com/media"]')
    ).map(img => img.src).slice(0, 4);

    // Thread context — collect subsequent tweet articles (same thread page)
    const threadTexts = [];
    for (let i = 1; i < Math.min(articles.length, 8); i++) {
      const text = articles[i]
        .querySelector('[data-testid="tweetText"]')
        ?.innerText?.trim();
      if (text) threadTexts.push(text);
    }

    return {
      platform: 'twitter',
      tweetText,
      authorName,
      authorHandle,
      timestamp,
      mediaUrls,
      threadTexts,
      url: window.location.href,
      pageTitle: document.title,
    };
  }

  // ── Reddit Extraction ─────────────────────────────────────────────────────

  function extractReddit() {
    // Supports new Reddit (shreddit) and old Reddit layouts.
    // New Reddit uses custom elements (shreddit-post); old uses class-based selectors.

    // ── Post title ──
    const postTitle =
      document.querySelector('h1[slot="title"]')?.innerText?.trim() ||           // new Reddit
      document.querySelector('[data-testid="post-title"]')?.innerText?.trim() || // transitional
      document.querySelector('.title.may-blank')?.innerText?.trim() ||            // old Reddit
      document.title;

    // ── Post body ──
    const postBody =
      document.querySelector('.md.feed-body')?.innerText?.trim() ||              // old Reddit
      document.querySelector('[data-testid="post-content"] .md')?.innerText?.trim() ||
      document.querySelector('div[data-testid="post-rtjson-content"]')?.innerText?.trim() ||
      '';

    // ── Subreddit ──
    const subredditMatch = window.location.pathname.match(/^\/r\/([^/]+)/);
    const subreddit = subredditMatch?.[1] ?? '';

    // ── Author ──
    const author =
      document.querySelector('[data-testid="post_author_link"]')?.innerText?.trim() ||
      document.querySelector('a[data-click-id="user"]')?.innerText?.trim() ||
      '';

    // ── Flair ──
    const flair =
      document.querySelector('[data-testid="post-flair-text"]')?.innerText?.trim() ||
      document.querySelector('.flair')?.innerText?.trim() ||
      '';

    // ── Score (upvotes) ──
    const score =
      document.querySelector('[data-testid="vote-arrows"] .score')?.innerText?.trim() ||
      document.querySelector('div[id^="vote-arrows"] .score')?.innerText?.trim() ||
      '';

    // ── Top comments (first 3, truncated) ──
    const commentSelectors = [
      '.Comment .RichTextJSON-root',        // new Reddit comment body
      '[data-testid="comment"] .md',        // transitional
      '.usertext-body .md',                 // old Reddit
    ];
    const topComments = [];
    for (const sel of commentSelectors) {
      const nodes = document.querySelectorAll(sel);
      if (nodes.length) {
        for (let i = 0; i < Math.min(nodes.length, 3); i++) {
          const text = nodes[i].innerText?.trim();
          if (text) topComments.push(text.slice(0, 600));
        }
        break;
      }
    }

    return {
      platform: 'reddit',
      postTitle,
      postBody: postBody.slice(0, 3000),
      subreddit,
      author,
      flair,
      score,
      topComments,
      url: window.location.href,
      pageTitle: document.title,
    };
  }

  // ── Message Listener ──────────────────────────────────────────────────────
  //
  // background.js sends { action: 'extract_content' } before capture.
  // We respond with the platform-specific payload.

  browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message.action !== 'extract_content') return false;

    let content = null;
    try {
      if (platform === 'twitter') {
        content = extractTwitter();
      } else if (platform === 'reddit') {
        content = extractReddit();
      }
    } catch (err) {
      console.error('[Cortex] Content extraction error:', err);
    }

    sendResponse({ success: true, content, platform });
    return true; // Keep message channel open
  });

})();
