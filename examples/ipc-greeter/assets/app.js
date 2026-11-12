const out = document.getElementById("out");
const log = document.getElementById("log");

// The bridge tells the page when it is ready, so a call never races injection.
window.myzig.on("myzig:ready", async () => {
  log.textContent = "connected to window " + window.myzig.windowId;
  // Make one call immediately so the IPC round trip is exercised without
  // needing a click, which also proves the bridge is usable at document start.
  try {
    out.textContent = await window.myzig.call("Greeter.greet", "Ada");
  } catch (err) {
    out.textContent = "Error (" + err.code + "): " + err.message;
  }
});

// A native event: Zig emits this every time a greeting is made.
window.myzig.on("greeted", (name) => {
  log.textContent = "event: greeted " + name;
});

document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const name = document.getElementById("name").value;
  try {
    // A typed call: the reply is already the value Zig returned.
    out.textContent = await window.myzig.call("Greeter.greet", name);
  } catch (err) {
    out.textContent = "Error (" + err.code + "): " + err.message;
  }
});
