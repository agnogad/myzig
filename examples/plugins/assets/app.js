// The plugin binds `Ticker.count` before the first page loads, so the call
// below needs no handshake beyond the bridge's own ready event.
const count = document.getElementById("count");
const log = document.getElementById("log");

// The plugin emits this from its own thread every 200 ms.
window.myzig.on("ticker", (value) => {
  count.textContent = value;
  log.textContent = "event from the plugin thread";
});

window.myzig.on("myzig:ready", async () => {
  const now = await window.myzig.call("Ticker.count");
  log.textContent = "Ticker.count answered " + now;
});
