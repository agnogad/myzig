// Drives the built-in desktop services. Each control reports its result into
// the log, so a failure is visible in the window rather than only in a
// terminal.
(function () {
  "use strict";

  var logEl = document.getElementById("log");
  var lines = 0;

  function label_of(text) {
    return String(text).replace(/<[^>]*>/g, "");
  }

  function log(text) {
    lines += 1;
    // Keep the log bounded: an unbounded log turns into a memory leak in a
    // window that stays open for days.
    if (lines > 60) {
      logEl.textContent = "";
      lines = 1;
    }
    var stamp = new Date().toLocaleTimeString();
    logEl.textContent += stamp + "  " + text + "\n";
    logEl.scrollTop = logEl.scrollHeight;
    // Mirror into the page console, which MyZig forwards to the terminal, so a
    // result is readable without a screenshot.
    console.log("desktop-api " + label_of(text));
  }

  function describe(value) {
    if (value === null || value === undefined) return "null";
    if (Array.isArray(value)) {
      return value.length === 0 ? "[no files]" : value.join(", ");
    }
    if (typeof value === "object") return JSON.stringify(value);
    return String(value);
  }

  // Every button follows the same shape: run one call, log the outcome, and
  // never leave an unhandled rejection behind.
  function bind(id, label, fn) {
    var el = document.getElementById(id);
    el.addEventListener("click", function () {
      el.disabled = true;
      Promise.resolve()
        .then(fn)
        .then(function (v) {
          log("<b>" + label + "</b>: " + describe(v));
        })
        .catch(function (err) {
          log("<b>" + label + "</b> failed: " + (err && err.message ? err.message : err));
        })
        .then(function () {
          el.disabled = false;
        });
    });
  }

  var api = window.myzig;
  if (!api) {
    logEl.textContent = "The MyZig bridge did not load.";
    return;
  }

  api.on("myzig:ready", function () {
    log("connected to window " + api.windowId + " (MyZig " + api.version + ")");
  });

  // The theme is reported by the platform, so the page can match native chrome.
  api.on("theme:changed", function (theme) {
    log("theme: " + theme);
  });

  bind("copy", "copy", function () {
    var text = document.getElementById("clip").value;
    return api.clipboard.writeText(text).then(function (ok) {
      return ok ? "copied " + text.length + " characters" : "the clipboard refused";
    });
  });

  bind("paste", "paste", function () {
    return api.clipboard.readText().then(function (text) {
      if (text === null) return "the clipboard holds no text";
      document.getElementById("clip").value = text;
      return text;
    });
  });

  bind("open", "open", function () {
    return api.dialog.open({ title: "Open a file" });
  });

  bind("save", "save", function () {
    return api.dialog.save({ title: "Save as", suggestedName: "untitled.txt" });
  });

  bind("ask", "ask", function () {
    return api.dialog.message({
      kind: "question",
      title: "A question",
      body: "This box comes from the GTK dialog."
    }).then(function (pressed) {
      return pressed === null ? "dismissed" : "button " + pressed;
    });
  });

  bind("notify", "notify", function () {
    return api.notify({
      title: "MyZig",
      body: "A notification from the Zig side."
    }).then(function (ok) {
      return ok ? "shown" : "the desktop refused the notification";
    });
  });

  bind("browse", "open external", function () {
    return api.openExternal("https://ziglang.org/").then(function (ok) {
      return ok ? "opened" : "no browser handler";
    });
  });

  bind("info", "app info", function () {
    return api.call("App.info");
  });

  // `?run=all` exercises the controls that do not open a modal, so the example
  // can be verified without synthetic mouse input. `?run=dialogs` opens the
  // message box, which needs a key press to close.
  var query = location.search;
  if (query.indexOf("run=all") !== -1) {
    ["copy", "paste", "info"].forEach(function (id, i) {
      setTimeout(function () {
        document.getElementById(id).click();
      }, 300 * (1 + i));
    });
  } else if (query.indexOf("run=dialogs") !== -1) {
    setTimeout(function () {
      document.getElementById("ask").click();
    }, 500);
  }
})();
