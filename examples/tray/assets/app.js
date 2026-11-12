(function () {
  "use strict";

  var logEl = document.getElementById("log");
  var api = window.myzig;
  if (!api) {
    logEl.textContent = "The MyZig bridge did not load.";
    return;
  }

  function log(text) {
    logEl.textContent += text + "\n";
    logEl.scrollTop = logEl.scrollHeight;
    console.log("tray-example " + text);
  }

  logEl.textContent = "";
  api.on("myzig:ready", function () {
    log("connected to window " + api.windowId);
  });
  api.on("tray:click", function () {
    log("tray clicked");
  });
  api.on("shortcut", function (payload) {
    log("shortcut: " + JSON.stringify(payload));
  });
})();
