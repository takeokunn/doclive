import { spawn, spawnSync } from "node:child_process";
import { access, mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const chromiumCandidates = [
  process.env.CHROMIUM_BIN,
  process.platform === "darwin" ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" : null,
  process.platform === "darwin" ? "/Applications/Chromium.app/Contents/MacOS/Chromium" : null,
  "chromium",
  "google-chrome",
].filter(Boolean);
let chromium;
for (const candidate of chromiumCandidates) {
  if (!candidate.includes("/")) {
    const result = spawnSync("which", [candidate], { encoding: "utf8" });
    if (result.status === 0) chromium = result.stdout.trim();
  } else {
    try {
      await access(candidate);
      chromium = candidate;
    } catch {}
  }
  if (chromium) break;
}
const emacs = process.env.EMACS || "emacs";

if (!chromium) {
  throw new Error("Chromium/Google Chrome was not found; set CHROMIUM_BIN explicitly");
}

const assetUrls = [
  ["highlight-css", "/assets/style.css"],
  ["katex-css", "/assets/style.css"],
  ["marked-script", "/assets/marked.js"],
  ["highlight-script", "/assets/highlight.js"],
  ["katex-script", "/assets/katex.js"],
  ["katex-auto-render-script", "/assets/katex-auto-render.js"],
  ["mermaid-script", "/assets/mermaid.js"],
];
const elispUrls = assetUrls
  .map(([name, url]) => `(${name} . ${JSON.stringify(url)})`)
  .join(" ");
const htmlResult = spawnSync(
  emacs,
  [
    "-Q",
    "--batch",
    "-L",
    ".",
    "-l",
    "doclive.el",
    "--eval",
    `(let ((doclive-preview-asset-urls '(${elispUrls})) (doclive-preview-asset-integrities nil)) (princ (doclive--preview-html)))`,
  ],
  { encoding: "utf8" },
);

if (htmlResult.status !== 0) {
  throw new Error(`failed to generate preview HTML:\n${htmlResult.stderr}`);
}

const assets = new Map([
  ["/assets/style.css", ""],
  [
    "/assets/marked.js",
    `globalThis.marked={setOptions(){},parse(source){const escaped=source.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));return escaped.split(/\\n\\n+/).map((part,index)=>index===0&&part.startsWith('# ')?'<h1>'+part.slice(2)+'</h1>':'<p>'+part.replace(/\\n/g,'<br>')+'</p>').join('');}};`,
  ],
  ["/assets/highlight.js", "globalThis.hljs={highlightElement(){}};"],
  ["/assets/katex.js", "globalThis.katex={};"],
  ["/assets/katex-auto-render.js", "globalThis.renderMathInElement=()=>{};"],
  [
    "/assets/mermaid.js",
    "globalThis.mermaid={initialize(){},async render(){return {svg:'<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>'};}};",
  ],
]);

const openStreams = new Set();
const server = createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (url.pathname === "/") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(htmlResult.stdout);
  } else if (url.pathname === "/content") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      ok: true,
      revision: 1,
      name: "browser-smoke.md",
      contentKind: "markdown",
      markdown: "# Browser Smoke\n\nNeedle alpha and needle beta.",
    }));
  } else if (url.pathname === "/events") {
    response.writeHead(200, {
      "cache-control": "no-cache",
      connection: "keep-alive",
      "content-type": "text/event-stream",
    });
    response.write('event: revision\ndata: {"revision":1}\n\n');
    openStreams.add(response);
    response.on("close", () => openStreams.delete(response));
  } else if (assets.has(url.pathname)) {
    const contentType = url.pathname.endsWith(".css") ? "text/css" : "text/javascript";
    response.writeHead(200, { "content-type": contentType });
    response.end(assets.get(url.pathname));
  } else {
    response.writeHead(404);
    response.end("not found");
  }
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});
const port = server.address().port;
const profile = await mkdtemp(join(tmpdir(), "doclive-browser-smoke-"));
const browser = spawn(chromium, [
  "--disable-background-networking",
  "--disable-component-update",
  "--disable-default-apps",
  "--disable-dev-shm-usage",
  "--disable-gpu",
  "--headless=new",
  "--no-first-run",
  "--no-sandbox",
  "--remote-debugging-port=0",
  `--user-data-dir=${profile}`,
  "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });

let browserStderr = "";
const websocketUrl = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`Chromium startup timed out:\n${browserStderr}`)), 15000);
  browser.stderr.setEncoding("utf8");
  browser.stderr.on("data", (chunk) => {
    browserStderr += chunk;
    const match = browserStderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
    if (match) {
      clearTimeout(timer);
      resolve(match[1]);
    }
  });
  browser.once("error", reject);
  browser.once("exit", (code) => reject(new Error(`Chromium exited early (${code}):\n${browserStderr}`)));
});

const socket = new WebSocket(websocketUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});

let sequence = 0;
const pending = new Map();
const browserErrors = [];
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) {
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
  }
  if (message.method === "Runtime.exceptionThrown") {
    browserErrors.push(message.params.exceptionDetails.text);
  }
  if (message.method === "Log.entryAdded" && message.params.entry.level === "error") {
    browserErrors.push(message.params.entry.text);
  }
});

function command(method, params = {}, sessionId) {
  const id = ++sequence;
  socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

try {
  const { targetId } = await command("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await command("Target.attachToTarget", { targetId, flatten: true });
  await command("Runtime.enable", {}, sessionId);
  await command("Log.enable", {}, sessionId);
  await command("Page.enable", {}, sessionId);
  await command("Page.navigate", { url: `http://127.0.0.1:${port}/?id=fixture` }, sessionId);

  const evaluate = async (expression) => {
    const result = await command("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    }, sessionId);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
  };
  const waitFor = async (expression, description) => {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      if (await evaluate(expression)) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`timed out waiting for ${description}`);
  };

  await waitFor("document.querySelector('#md h1')?.textContent === 'Browser Smoke'", "initial rendering");
  assert(await evaluate("document.querySelector('#status').textContent.includes('live') && document.querySelector('#status').textContent.includes('browser-smoke.md')"), "live status was not rendered");

  await evaluate("search.value='needle'; search.dispatchEvent(new Event('input',{bubbles:true})); pin.click();");
  assert(await evaluate("document.querySelectorAll('#md mark').length >= 2"), "search highlights were not rendered");
  assert(await evaluate("document.querySelector('#chips .chip b')?.textContent === 'needle'"), "pinned search chip was not rendered");

  await evaluate("theme.value='light'; theme.dispatchEvent(new Event('change',{bubbles:true}));");
  assert(await evaluate("document.body.dataset.theme === 'light'"), "theme control did not apply light mode");

  await evaluate("document.querySelector('#zoom-in').click()");
  assert(await evaluate("document.querySelector('#md').style.fontSize === '110%'"), "zoom-in control did not change content size");
  await evaluate("document.querySelector('#zoom-reset').click()");
  assert(await evaluate("document.querySelector('#md').style.fontSize === '100%'"), "zoom reset did not restore content size");

  assert(browserErrors.length === 0, `browser console errors:\n${browserErrors.join("\n")}`);
  process.stdout.write("browser smoke passed: render, status, search/pin, theme, zoom\n");
} finally {
  socket.close();
  browser.kill("SIGTERM");
  for (const stream of openStreams) stream.end();
  await new Promise((resolve) => server.close(resolve));
  await rm(profile, { recursive: true, force: true });
}
