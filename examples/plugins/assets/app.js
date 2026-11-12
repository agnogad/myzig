const count = document.getElementById("count");
const log = document.getElementById("log");

window.myzig.on("ticker", (value) => {
  count.textContent = value;
});

window.myzig.on("myzig:ready", async () => {
  const now = await window.myzig.call("Ticker.count");
  log.textContent = "Ticker.count answered " + now;
  // The event goes both to this page's own listeners and to the Zig side.
  window.myzig.emit("ui:clicked", { id: now });
  console.log("SENT page event with id " + now);
});
