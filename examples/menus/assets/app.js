// Shows every menu command the framework reports.
(function () {
  "use strict";

  var logEl = document.getElementById("log");
  var lines = 0;

  function log(text) {
    lines += 1;
    if (lines > 60) {
      logEl.textContent = "";
      lines = 1;
    }
    logEl.textContent += text + "\n";
    logEl.scrollTop = logEl.scrollHeight;
    console.log("menus " + text);
  }

  var api = window.myzig;
  if (!api) {
    logEl.textContent = "The MyZig bridge did not load.";
    return;
  }

  api.on("myzig:ready", function () {
    log("connected to window " + api.windowId);
  });

  // The framework reports a click as `menu:command` with the id the Zig menu
  // declared, so the page and the application share one set of names.
  api.on("menu:command", function (payload) {
    log("command: " + (payload && payload.value ? payload.value : JSON.stringify(payload)));
  });

  // The Quit entry is a role: the framework quits, and telling the user why the
  // window closed is the application's job.
  api.on("app:before-quit", function () {
    log("quitting");
  });
})();
