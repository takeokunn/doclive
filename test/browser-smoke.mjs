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
    `globalThis.marked={setOptions(o){globalThis.markedOptions=o;},parse(source){` +
      `const esc=(s)=>s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));` +
      `const blocks=source.split(/\\n\\n+/);` +
      `return blocks.map((part,index)=>{` +
      `if(index===0&&part.startsWith('# ')) return '<h1>'+esc(part.slice(2))+'</h1>';` +
      `const fence=part.match(/^\`\`\`(\\S*)\\n([\\s\\S]*?)\\n\`\`\`\\s*$/);` +
      `if(fence){const cls=fence[1]==='mermaid'?' class="language-mermaid"':''; return '<pre><code'+cls+'>'+esc(fence[2])+'</code></pre>';}` +
      `const firstLine=part.split('\\n')[0].trim();` +
      `if(firstLine.startsWith('|')&&firstLine.endsWith('|')){` +
      `const rows=part.split('\\n').filter((line)=>line.trim().startsWith('|'));` +
      `const body=rows.map((row)=>'<tr>'+row.split('|').slice(1,-1).map((cell)=>'<td>'+esc(cell.trim())+'</td>').join('')+'</tr>').join('');` +
      `return '<table>'+body+'</table>';}` +
      `const task=part.match(/^-\\s\\[ \\]\\s(.*)$/);` +
      `if(task) return '<ul><li><input type="checkbox" disabled> '+esc(task[1])+'</li></ul>';` +
      `return '<p>'+esc(part).replace(/\\n/g,'<br>')+'</p>';` +
      `}).join('');}};`,
  ],
  ["/assets/highlight.js", "globalThis.hljs={highlightElement(){}};"],
  ["/assets/katex.js", "globalThis.katex={};"],
  ["/assets/katex-auto-render.js", "globalThis.renderMathInElement=()=>{};"],
  [
    "/assets/mermaid.js",
    "globalThis.mermaid={initialize(){},async render(){return {svg:'<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 3000 200\" width=\"100%\" style=\"max-width:3000px;\"></svg>'};}};",
  ],
]);

const openStreams = new Set();
const wikiPages = new Map([
  ["wiki-home", { path: "README.md", name: "Handbook", markdown: "# Handbook\n\nChoose a guide from the explorer.\n" }],
  ["wiki-storage", { path: "reference/storage.md", name: "Storage", markdown: "# Storage\n\n設定の変更は再起動なしで反映されます。\n" }],
]);
const wikiState = { bookmarks: [], recent: ["README.md"], pins: [], theme: "dark", zoom: 1 };
const copiedTexts = [];
const openedPaths = [];
const server = createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  const wikiPage = wikiPages.get(url.searchParams.get("id"));
  if (url.pathname === "/") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(htmlResult.stdout);
  } else if (url.pathname === "/content") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(wikiPage ? {
      ok: true, revision: 1, name: wikiPage.path, contentKind: "markdown", markdown: wikiPage.markdown,
    } : {
      ok: true,
      revision: 1,
      name: "browser-smoke.md",
      contentKind: "markdown",
      markdown: "# Browser Smoke\n\nNeedle alpha and needle beta.\n\nThis line wraps\ninto a second line.\n\n| Col A | Col B |\n| --- | --- |\n| one | two |\n\n- [ ] Todo item\n\n```js\nconst greeting = 'hi';\n```\n\n```mermaid\ngraph TD; A-->B;\n```\n",
    }));
  } else if (url.pathname === "/copy") {
    copiedTexts.push(JSON.parse(url.searchParams.get("text")));
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true }));
  } else if (url.pathname === "/workspace") {
    for (const key of ["theme", "zoom", "pins"]) {
      if (!url.searchParams.has(key)) continue;
      const value = url.searchParams.get(key);
      wikiState[key] = key === "zoom" ? Number(value) : key === "pins" ? JSON.parse(value) : value;
    }
    if (url.searchParams.has("bookmark")) {
      const path = url.searchParams.get("bookmark");
      wikiState.bookmarks = wikiState.bookmarks.filter((item) => item !== path);
      if (url.searchParams.get("value") === "1") wikiState.bookmarks.push(path);
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(wikiPage ? {
      ok: true, workspace: true, name: "handbook", current: wikiPage.path,
      files: [...wikiPages.values()].map(({ path, name }) => ({ path, name })), ...wikiState,
    } : { ok: true, workspace: false }));
  } else if (url.pathname === "/search") {
    const query = url.searchParams.get("q") || "";
    const results = [...wikiPages.values()].filter((page) => query && page.markdown.includes(query))
      .map(({ path, name, markdown }) => ({ path, name, snippet: markdown }));
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true, results }));
  } else if (url.pathname === "/open") {
    openedPaths.push(url.searchParams.get("path"));
    const found = [...wikiPages].find(([, page]) => page.path === url.searchParams.get("path"));
    if (found) wikiState.recent = [found[1].path, ...wikiState.recent.filter((path) => path !== found[1].path)];
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(found ? { ok: true, buffer_id: found[0] } : { ok: false, error: "Missing page" }));
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
const browserExit = new Promise((resolve) => browser.once("exit", resolve));
const waitForBrowserExit = (timeout) => new Promise((resolve) => {
  const timer = setTimeout(() => resolve(false), timeout);
  browserExit.then(() => {
    clearTimeout(timer);
    resolve(true);
  });
});

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
  await waitFor("document.querySelector('#status').textContent.includes('live') && document.querySelector('#status').textContent.includes('browser-smoke.md')", "live status rendering");

  await evaluate("search.value='needle'; search.dispatchEvent(new Event('input',{bubbles:true})); pin.click();");
  assert(await evaluate("document.querySelectorAll('#md mark').length >= 2"), "search highlights were not rendered");
  assert(await evaluate("document.querySelector('#chips .chip b')?.textContent === 'needle'"), "pinned search chip was not rendered");

  await evaluate("theme.value='light'; theme.dispatchEvent(new Event('change',{bubbles:true}));");
  assert(await evaluate("document.body.dataset.theme === 'light'"), "theme control did not apply light mode");

  await evaluate("document.querySelector('#zoom-in').click()");
  assert(await evaluate("document.querySelector('#md').style.fontSize === '110%'"), "zoom-in control did not change content size");
  await evaluate("document.querySelector('#zoom-reset').click()");
  assert(await evaluate("document.querySelector('#md').style.fontSize === '100%'"), "zoom reset did not restore content size");

  assert(await evaluate("globalThis.markedOptions && globalThis.markedOptions.breaks === false"), "marked breaks option was not disabled");
  assert(await evaluate("document.title === 'browser-smoke.md - doclive'"), "document title was not set from document name");
  assert(await evaluate("!!document.querySelector('#md .table-wrap table')"), "table was not wrapped in .table-wrap");
  assert(await evaluate("(()=>{const li=document.querySelector('#md li'); return !!li && getComputedStyle(li).listStyleType==='none';})()"), "task list item did not have list-style:none");

  await waitFor("!!document.querySelector('.mermaid-holder svg')", "mermaid svg render");
  assert(await evaluate("document.querySelector('.mermaid-holder svg').getBoundingClientRect().width > 1000"), "mermaid svg did not render at natural oversized width");
  assert(await evaluate("(()=>{const h=document.querySelector('.mermaid-holder'); return h.scrollWidth>h.clientWidth;})()"), "mermaid holder was not horizontally scrollable");

  await evaluate("document.querySelectorAll('.mermaid-tools button')[0].click();");
  assert(await evaluate("(()=>{const h=document.querySelector('.mermaid-holder'); const svg=h.querySelector('svg'); return svg.getBoundingClientRect().width<=h.clientWidth;})()"), "Fit control did not shrink svg to holder width");

  await evaluate("const expandBtn=document.querySelectorAll('.mermaid-tools button')[2]; expandBtn.focus(); expandBtn.click();");
  assert(await evaluate("(()=>{const o=document.getElementById('mermaid-overlay'); return !!o && !!o.querySelector('svg') && getComputedStyle(o).display!=='none';})()"), "Expand control did not open a visible mermaid overlay");
  assert(await evaluate("(()=>{const h=document.querySelector('.mermaid-holder'); const overlaySvg=document.querySelector('#mermaid-overlay svg'); return overlaySvg.getBoundingClientRect().width>h.clientWidth;})()"), "Expand overlay did not show the diagram at natural size after Fit");
  assert(await evaluate("document.querySelector('#mermaid-overlay svg').style.width===''"), "Expand overlay svg retained an inline width from Fit");
  assert(await evaluate("document.activeElement===document.querySelector('.mermaid-overlay-close')"), "focus did not move to the overlay close button on open");

  await evaluate("document.querySelector('.mermaid-overlay-close').click();");
  assert(await evaluate("!document.getElementById('mermaid-overlay')"), "close button did not remove the mermaid overlay");
  assert(await evaluate("document.activeElement===document.querySelectorAll('.mermaid-tools button')[2]"), "focus did not return to the Expand button after close");

  await evaluate("window.docliveSetSearch('needle');");
  assert(await evaluate("document.querySelectorAll('#md mark').length >= 2"), "docliveSetSearch did not highlight matches");
  assert(await evaluate("window.docliveSearchNext(false).index === 2"), "next match did not advance");
  assert(await evaluate("window.docliveSearchNext(true).index === 1"), "previous match did not return");
  assert(await evaluate("(()=>{search.focus();search.value='検索テキスト';search.setSelectionRange(0,2);return window.docliveGetSelection()==='検索';})()"), "input selection was not copied");
  assert(await evaluate("window.docliveGetSearch(false)==='検索テキスト'"), "native search did not read the visible page query");
  assert(await evaluate("(()=>{window.doclivePaste('needle');return search.value==='needleテキスト'&&search.selectionStart===6&&document.activeElement===search;})()"), "paste did not replace the focused search selection");
  assert(await evaluate("(()=>{search.value='nee';search.setSelectionRange(3,3);window.doclivePaste('dle');return search.value==='needle'&&document.querySelectorAll('#md .search-match').length>=2;})()"), "paste did not update page matches");
  assert(await evaluate("(()=>{search.blur();window.doclivePaste('needle');return search.value==='needle'&&document.activeElement===search;})()"), "paste without an input did not focus page search");
  assert(await evaluate("(()=>{search.blur();const r=document.createRange();r.selectNodeContents(document.querySelector('#md h1'));const s=getSelection();s.removeAllRanges();s.addRange(r);return window.docliveGetSelection()==='Browser Smoke';})()"), "body selection was not copied");

  await evaluate("Object.defineProperty(navigator,'clipboard',{value:undefined,configurable:true}); document.execCommand=(cmd)=>{globalThis.execCalls=(globalThis.execCalls||[]).concat(cmd); return cmd==='copy';};");
  await evaluate("document.querySelector('.copy-btn').click();");
  await waitFor("document.querySelector('.copy-btn').textContent==='Copied'", "copy button fallback result");
  assert(await evaluate("Array.isArray(globalThis.execCalls) && globalThis.execCalls.includes('copy')"), "copy fallback did not invoke execCommand('copy')");
  assert(copiedTexts.includes("const greeting = 'hi';"), "code Copy did not send its text to the native bridge");

  await command("Page.navigate", { url: `http://127.0.0.1:${port}/?id=wiki-home` }, sessionId);
  await waitFor("document.querySelectorAll('#wiki-files .wiki-page').length === 2", "Wiki explorer");
  await evaluate("(()=>{const toggle=document.getElementById('wiki-toggle');if(toggle.getAttribute('aria-expanded')==='false')toggle.click();})()");
  assert(await evaluate("(()=>{const input=document.getElementById('wiki-search');input.focus();return document.activeElement===input;})()"), "Wiki paste precondition: search input did not receive focus");
  await evaluate("(()=>{const input=document.getElementById('wiki-search');input.focus();input.value='再xx';input.setSelectionRange(1,3);window.doclivePaste('起動');})()");
  await waitFor("document.querySelectorAll('#wiki-results .wiki-page').length === 1", "pasted Wiki search");
  assert(await evaluate("document.getElementById('wiki-search').value==='再起動'&&document.getElementById('search').value===''") , "Wiki paste changed the wrong search input");
  assert(await evaluate("window.docliveGetSearch(true)==='再起動'&&window.docliveGetSearch(false)===''"), "native search did not distinguish Wiki and empty page queries");
  await evaluate("window.docliveSetWikiSearch('')");
  await waitFor("!document.getElementById('wiki-files').hidden && document.getElementById('wiki-results').hidden && document.querySelectorAll('#wiki-files .wiki-page').length === 2", "Wiki search cleared after paste");
  assert(await evaluate("document.querySelector('#wiki-path').textContent === 'README.md'"), "Wiki did not open its README");
  await evaluate("document.querySelector('#wiki-bookmark').click()");
  await waitFor("document.querySelector('#wiki-bookmark').getAttribute('aria-pressed') === 'true'", "bookmark save");
  await evaluate("document.querySelector('[data-filter=bookmarks]').click()");
  assert(await evaluate("document.querySelectorAll('#wiki-files .wiki-page').length === 1"), "Saved filter did not narrow pages");
  await evaluate("document.querySelector('[data-filter=all]').click(); document.dispatchEvent(new KeyboardEvent('keydown',{key:'k',ctrlKey:true,bubbles:true}));");
  assert(await evaluate("document.activeElement.id === 'wiki-search'"), "search shortcut did not move focus");
  await evaluate("const ws=document.querySelector('#wiki-search'); ws.value='再起動'; ws.dispatchEvent(new Event('input'));");
  await waitFor("document.querySelectorAll('#wiki-results .wiki-page').length === 1", "Japanese body search");
  assert(await evaluate("document.querySelector('#wiki-results .snippet').textContent.includes('再起動')"), "search result did not include its matching context");
  const opensBeforeComposition = openedPaths.length;
  for (const composition of [{ isComposing: true }, { isComposing: false, keyCode: 229 }]) {
    const label = JSON.stringify(composition);
    for (const key of ["Enter", "ArrowDown", "ArrowUp", "Escape"]) {
      const state = await evaluate(`(()=>{
        const input=document.querySelector('#wiki-search');
        const beforeUrl=location.href;
        const event=new KeyboardEvent('keydown',${JSON.stringify({ bubbles: true, cancelable: true, key, ...composition })});
        input.dispatchEvent(event);
        return {
          isComposing:event.isComposing,keyCode:event.keyCode,
          prevented:event.defaultPrevented,focused:document.activeElement===input,
          query:input.value,expanded:document.querySelector('#wiki-toggle').getAttribute('aria-expanded'),
          closed:document.body.classList.contains('explorer-closed'),
          busy:document.querySelector('#md').hasAttribute('aria-busy'),
          sameUrl:location.href===beforeUrl,path:document.querySelector('#wiki-path').textContent
        };
      })()`);
      assert(state.isComposing === composition.isComposing && state.keyCode === (composition.keyCode || 0), `composition event precondition failed: ${label}`);
      assert(!state.busy && state.sameUrl && state.path === "README.md", `composing ${key} initiated navigation: ${label} ${JSON.stringify(state)}`);
      assert(!state.prevented && state.focused, `composing ${key} prevented default or moved focus: ${label}`);
      assert(state.query === "再起動" && state.expanded === "true" && !state.closed, `composing ${key} changed query or explorer: ${label}`);
      assert(openedPaths.length === opensBeforeComposition, `composing ${key} initiated /open: ${label}`);
    }
  }
  await evaluate("document.querySelector('#wiki-search').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))");
  await waitFor("document.querySelector('#wiki-path').textContent === 'reference/storage.md'", "search result navigation");
  assert(await evaluate("document.querySelector('#md h1').textContent === 'Storage'"), "selected page content was not loaded");
  assert(openedPaths.length === opensBeforeComposition + 1 && openedPaths.at(-1) === "reference/storage.md", "ordinary Enter did not make exactly one /open request after composition");
  await evaluate("history.back()");
  await waitFor("document.querySelector('#wiki-path').textContent === 'README.md'", "browser back navigation");
  await evaluate("history.forward()");
  await waitFor("document.querySelector('#wiki-path').textContent === 'reference/storage.md'", "browser forward navigation");
  await evaluate("theme.value='light'; theme.dispatchEvent(new Event('change')); document.querySelector('#zoom-in').click(); search.value='再起動'; search.dispatchEvent(new Event('input')); pin.click();");
  await waitFor("document.querySelector('#chips .chip b')?.textContent === '再起動'", "Wiki search pin");
  const savedDeadline = Date.now() + 10000;
  while (wikiState.theme !== "light" || wikiState.zoom !== 1.1 || wikiState.pins[0] !== "再起動") {
    assert(Date.now() < savedDeadline, "Wiki preferences were not saved to the server");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  await command("Page.reload", {}, sessionId);
  await waitFor("document.querySelector('#wiki-path')?.textContent === 'reference/storage.md' && document.body.dataset.theme === 'light'", "Wiki preference restoration");
  assert(await evaluate("document.querySelector('#md').style.fontSize === '110%' && document.querySelector('#chips .chip b')?.textContent === '再起動'"), "Wiki zoom or pins were not restored");
  await command("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 1, mobile: true }, sessionId);
  await command("Page.reload", {}, sessionId);
  await waitFor("document.querySelector('#wiki-path')?.textContent === 'reference/storage.md'", "narrow Wiki layout");
  assert(await evaluate("document.documentElement.scrollWidth <= innerWidth"), "narrow Wiki layout overflowed horizontally");
  assert(await evaluate("document.body.classList.contains('explorer-closed')"), "narrow Wiki did not start with the explorer closed");
  await evaluate("document.querySelector('#wiki-toggle').click()");
  assert(await evaluate("document.activeElement.id === 'wiki-search' && document.querySelector('#wiki-toggle').getAttribute('aria-expanded') === 'true'"), "narrow explorer did not open with search focus");
  for (const composition of [{ isComposing: true }, { isComposing: false, keyCode: 229 }]) {
    assert(await evaluate(`(()=>{
      const input=document.querySelector('#wiki-search');
      const event=new KeyboardEvent('keydown',${JSON.stringify({ key: "Escape", bubbles: true, cancelable: true, ...composition })});
      input.dispatchEvent(event);
      return !event.defaultPrevented && document.activeElement===input && input.value==='' &&
        document.querySelector('#wiki-toggle').getAttribute('aria-expanded')==='true' && !document.body.classList.contains('explorer-closed');
    })()`), `composing Escape closed the empty-query explorer: ${JSON.stringify(composition)}`);
  }
  await evaluate("document.querySelector('#wiki-search').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))");
  assert(await evaluate("document.activeElement.id === 'wiki-toggle' && document.body.classList.contains('explorer-closed')"), "Escape did not close the explorer and return focus");
  assert(await evaluate("window.docliveSetWikiSearch('再起動')"), "xwidget Wiki search bridge did not accept text");
  await waitFor("document.querySelectorAll('#wiki-results .wiki-page').length === 1", "native Wiki search results");
  await evaluate("window.docliveSetSearch('再起動');window.docliveDismiss()");
  assert(await evaluate("search.value === '' && document.querySelector('#wiki-search').value === '' && document.body.classList.contains('explorer-closed')"), "native dismiss did not clear search and close the explorer");

  assert(browserErrors.length === 0, `browser console errors:\n${browserErrors.join("\n")}`);
  process.stdout.write("browser smoke passed: rendering, search/navigation, theme/zoom, Mermaid, selection/copy bridge, Wiki search/bookmarks/history/preferences, narrow layout and focus\n");
} finally {
  socket.close();
  for (const stream of openStreams) stream.end();
  browser.kill("SIGTERM");
  const exitedAfterSigterm = await waitForBrowserExit(5000);
  if (!exitedAfterSigterm) {
    browser.kill("SIGKILL");
    await browserExit;
  }
  await new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
    server.closeAllConnections();
  });
  const cleanupDeadline = Date.now() + 5000;
  for (;;) {
    try {
      await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
      break;
    } catch (error) {
      if (error.code !== "ENOTEMPTY" || Date.now() >= cleanupDeadline) throw error;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
}
