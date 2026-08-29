#!/usr/bin/env node
'use strict';

// CLI driver for sandbox-gateway's browser routes (spec docs/agent-platform-v1.md §3.6).
// Usage: node browser.js '<json request>' — prints exactly one JSON line to stdout.
const { spawn } = require('child_process');
const dns = require('dns').promises;
const net = require('net');
const { chromium } = require('playwright-core');

const CDP_PORT = 9222;
const CDP_URL = `http://127.0.0.1:${CDP_PORT}`;
const USER_DATA_DIR = '/home/agent/.vibe-browser';
const CHROMIUM_PATH = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || '/usr/bin/chromium';
const DEFAULT_MAX_WIDTH = 1024;
const NAV_TIMEOUT_MS = 20000;
const ACTION_TIMEOUT_MS = 10000;
const LAUNCH_WAIT_MS = 15000;

// [network, prefix bits] — SSRF guard for navigate/click-driven navigation.
const BLOCKED_V4_RANGES = [
  ['127.0.0.0', 8],
  ['10.0.0.0', 8],
  ['172.16.0.0', 12],
  ['192.168.0.0', 16],
  ['169.254.0.0', 16],
];

function ipToInt(ip) {
  const parts = ip.split('.').map(Number);
  if (parts.length !== 4 || parts.some((p) => Number.isNaN(p) || p < 0 || p > 255)) return null;
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}

function isBlockedV4(ip) {
  const value = ipToInt(ip);
  if (value === null) return false;
  return BLOCKED_V4_RANGES.some(([base, bits]) => {
    const mask = bits === 0 ? 0 : (~0 << (32 - bits)) >>> 0;
    return (value & mask) === (ipToInt(base) & mask);
  });
}

// Resolves the hostname and blocks private/link-local targets; a DNS failure is not a security
// block (the container's egress proxy is the real perimeter — see deploy/egress-proxy).
async function assertSafeUrl(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new Error('invalid url');
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`blocked scheme: ${url.protocol}`);
  }
  const host = url.hostname;
  if (net.isIP(host) === 4) {
    if (isBlockedV4(host)) throw new Error(`blocked host: ${host}`);
    return url;
  }
  try {
    const { address } = await dns.lookup(host, { family: 4 });
    if (isBlockedV4(address)) throw new Error(`blocked host: ${host} resolves to ${address}`);
  } catch (e) {
    if (e && /^blocked host/.test(e.message)) throw e;
  }
  return url;
}

function cdpReachable() {
  return fetch(`${CDP_URL}/json/version`).then((r) => r.ok).catch(() => false);
}

async function waitForCdp(deadline) {
  while (Date.now() < deadline) {
    if (await cdpReachable()) return true;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  return false;
}

// Launches ONE persistent, detached Chromium; later CLI invocations reconnect over CDP instead
// of relaunching, so browser state (cookies, tabs) survives across separate `node browser.js` runs.
async function launchChromium() {
  const args = [
    '--headless=new',
    `--remote-debugging-port=${CDP_PORT}`,
    `--user-data-dir=${USER_DATA_DIR}`,
    '--no-sandbox',
    '--disable-gpu',
  ];
  if (process.env.HTTPS_PROXY) {
    args.push(`--proxy-server=${process.env.HTTPS_PROXY}`);
  }
  const child = spawn(CHROMIUM_PATH, args, { detached: true, stdio: 'ignore' });
  child.unref();
  const ready = await waitForCdp(Date.now() + LAUNCH_WAIT_MS);
  if (!ready) throw new Error('chromium did not become ready on the CDP port');
}

async function ensureBrowser() {
  if (!(await cdpReachable())) {
    await launchChromium();
  }
  return chromium.connectOverCDP(CDP_URL);
}

async function getPage(browser) {
  const context = browser.contexts()[0] || (await browser.newContext());
  return context.pages()[0] || context.newPage();
}

async function runAction(page, action) {
  switch (action.kind) {
    case 'click':
      await page.click(action.selector, { timeout: ACTION_TIMEOUT_MS });
      return;
    case 'type':
      await page.fill(action.selector, String(action.text ?? ''), { timeout: ACTION_TIMEOUT_MS });
      return;
    case 'key':
      await page.keyboard.press(String(action.text ?? ''));
      return;
    case 'select':
      await page.selectOption(action.selector, String(action.text ?? ''), { timeout: ACTION_TIMEOUT_MS });
      return;
    case 'scroll':
      await page.mouse.wheel(Number(action.x) || 0, Number(action.y) || 0);
      return;
    default:
      throw new Error(`unknown action kind: ${action.kind}`);
  }
}

// Renders at exactly maxWidth instead of capturing full-size then downscaling: no image
// library needed, and it keeps every screenshot at a predictable, bounded size.
async function takeScreenshot(page, maxWidth) {
  const width = Number(maxWidth) > 0 ? Math.floor(Number(maxWidth)) : DEFAULT_MAX_WIDTH;
  const current = page.viewportSize();
  if (!current || current.width !== width) {
    const ratio = current ? current.height / current.width : 9 / 16;
    await page.setViewportSize({ width, height: Math.round(width * ratio) });
  }
  const buffer = await page.screenshot({ type: 'jpeg', quality: 70 });
  const size = page.viewportSize();
  return { imageBase64: buffer.toString('base64'), mime: 'image/jpeg', width: size.width, height: size.height };
}

// Never calls browser.close(): that sends CDP Browser.close and would kill the persistent
// process. Exiting this short-lived Node process just drops our one connection to it.
async function handle(request) {
  const browser = await ensureBrowser();
  const page = await getPage(browser);
  switch (request.kind) {
    case 'status':
      return { ok: true };
    case 'navigate': {
      const url = await assertSafeUrl(request.url);
      await page.goto(url.toString(), { timeout: NAV_TIMEOUT_MS, waitUntil: 'domcontentloaded' });
      return { url: page.url(), title: await page.title() };
    }
    case 'action':
      await runAction(page, request.action || {});
      return { ok: true, url: page.url(), title: await page.title() };
    case 'screenshot':
      return takeScreenshot(page, request.maxWidth);
    default:
      throw new Error(`unknown kind: ${request.kind}`);
  }
}

// Writes the one required JSON line, waits for the flush to land, then exits — exiting right
// after an unflushed pipe write can truncate stdout.
function emit(payload, code) {
  process.stdout.write(`${JSON.stringify(payload)}\n`, () => process.exit(code));
}

process.on('unhandledRejection', (err) => {
  emit({ error: String((err && err.message) || err) }, 1);
});

async function main() {
  let request;
  try {
    request = JSON.parse(process.argv[2]);
  } catch {
    emit({ error: 'invalid json argument' }, 1);
    return;
  }
  try {
    emit(await handle(request), 0);
  } catch (err) {
    emit({ error: String((err && err.message) || err) }, 1);
  }
}

main();
