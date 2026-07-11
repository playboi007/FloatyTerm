// Options / popup: show bridge status and let the user set the optional token.

async function refreshStatus() {
  const el = document.getElementById("status");
  // Probe the relay over plain HTTP (GET /floaty.js is side-effect-free). Never
  // probe by opening a WebSocket to /cdp-bridge: the bridge keeps ONE live
  // connection (latest wins), so a probe socket would kick the service worker's
  // real connection off — a status check that breaks the thing it checks.
  try {
    const r = await fetch("http://127.0.0.1:7777/floaty.js", { cache: "no-store" });
    const up = r.ok;
    el.textContent = up ? "FloatyTerm relay reachable ✓" : "FloatyTerm relay not reachable";
    el.className = "status " + (up ? "up" : "down");
  } catch (e) {
    el.textContent = "FloatyTerm relay not reachable";
    el.className = "status down";
  }
}

function pokeWorker() {
  // Waking the SW (message delivery) re-runs its top-level connect(); the
  // listener also force-redials so a token change takes effect immediately.
  try { chrome.runtime.sendMessage({ type: "reconnect" }, () => void chrome.runtime.lastError); }
  catch (e) {}
}

async function load() {
  const { floatyToken } = await chrome.storage.local.get("floatyToken");
  document.getElementById("token").value = floatyToken || "";
  refreshStatus();
}

document.getElementById("save").addEventListener("click", async () => {
  await chrome.storage.local.set({ floatyToken: document.getElementById("token").value.trim() });
  pokeWorker();
  refreshStatus();
});

document.getElementById("reconnect").addEventListener("click", () => {
  pokeWorker();
  setTimeout(refreshStatus, 500);
});

load();
