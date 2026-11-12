(function () {
  "use strict";
  var W = window;
  if (W.__myzig_installed) return;
  Object.defineProperty(W, "__myzig_installed", { value: true });

  var HANDLER = "@@HANDLER@@";
  var SECRET = "@@SECRET@@";
  var WINDOW_ID = @@WINDOW_ID@@;
  var VERSION = "@@VERSION@@";

  function post(payload) {
    payload.s = SECRET;
    try {
      W.webkit.messageHandlers[HANDLER].postMessage(JSON.stringify(payload));
    } catch (e) {
      // No handler means the page runs outside MyZig (a browser, a test
      // harness). Calls then reject rather than hang.
      throw new Error("myzig: native bridge unavailable");
    }
  }

  var nextId = 1;
  var pending = new Map();
  var listeners = new Map();
  var outbox = [];
  var flushScheduled = false;

  function flush() {
    flushScheduled = false;
    if (outbox.length === 0) return;
    var batch = outbox;
    outbox = [];
    post({ t: "batch", m: batch });
  }

  function enqueue(msg) {
    outbox.push(msg);
    if (!flushScheduled) {
      flushScheduled = true;
      // Batch everything the page sends in one task into one message, which
      // keeps a burst of calls to a single crossing of the process boundary.
      Promise.resolve().then(flush);
    }
  }

  function emit(name, data) {
    var set = listeners.get(name);
    if (!set) return;
    var arr = Array.from(set);
    for (var i = 0; i < arr.length; i++) {
      try {
        arr[i](data);
      } catch (e) {
        console.error("myzig: listener for " + name + " threw", e);
      }
    }
  }

  var api = {
    version: VERSION,
    platform: "@@PLATFORM@@",
    windowId: WINDOW_ID,

    call: function (method) {
      var args = Array.prototype.slice.call(arguments, 1);
      var id = nextId++;
      return new Promise(function (resolve, reject) {
        pending.set(id, { resolve: resolve, reject: reject });
        enqueue({ t: "call", id: id, m: method, a: args });
      });
    },

    on: function (name, fn) {
      var set = listeners.get(name);
      if (!set) {
        set = new Set();
        listeners.set(name, set);
        enqueue({ t: "sub", e: name });
      }
      set.add(fn);
      return function () {
        api.off(name, fn);
      };
    },

    once: function (name, fn) {
      var off = api.on(name, function (data) {
        off();
        fn(data);
      });
      return off;
    },

    off: function (name, fn) {
      var set = listeners.get(name);
      if (!set) return;
      set.delete(fn);
      if (set.size === 0) {
        listeners.delete(name);
        enqueue({ t: "unsub", e: name });
      }
    },

    cancel: function (id) {
      enqueue({ t: "cancel", id: id });
    },

    window: {
      minimize: function () { return api.call("Window.minimize"); },
      maximize: function () { return api.call("Window.maximize"); },
      unmaximize: function () { return api.call("Window.unmaximize"); },
      fullscreen: function (on) { return api.call("Window.fullscreen", on !== false); },
      restore: function () { return api.call("Window.restore"); },
      focus: function () { return api.call("Window.focus"); },
      setTitle: function (t) { return api.call("Window.setTitle", t); },
      setSize: function (w, h) { return api.call("Window.setSize", w, h); },
      setPosition: function (x, y) { return api.call("Window.setPosition", x, y); },
      close: function () { return api.call("Window.close"); },
      state: function () { return api.call("Window.state"); },
      bounds: function () { return api.call("Window.bounds"); },
      openDevtools: function () { return api.call("Window.openDevtools"); },
      setAlwaysOnTop: function (on) { return api.call("Window.setAlwaysOnTop", !!on); }
    },

    clipboard: {
      readText: function () { return api.call("Clipboard.readText"); },
      writeText: function (t) { return api.call("Clipboard.writeText", t); }
    },

    dialog: {
      open: function (o) { return api.call("Dialog.open", o); },
      save: function (o) { return api.call("Dialog.save", o); },
      message: function (o) { return api.call("Dialog.message", o); }
    },

    notify: function (o) { return api.call("Notification.show", o); },

    openExternal: function (url) { return api.call("Shell.openExternal", url); }
  };

  // The framework calls this exactly once with replies and events for this
  // window. Arguments are read defensively: a malformed message is dropped, not
  // thrown, so one bad batch cannot break the page.
  var receive = function (text) {
    var list;
    try {
      list = typeof text === "string" ? JSON.parse(text) : text;
    } catch (e) {
      console.error("myzig: unparseable native message", e);
      return;
    }
    if (!Array.isArray(list)) return;
    for (var i = 0; i < list.length; i++) {
      var msg = list[i];
      if (!msg || typeof msg !== "object") continue;
      switch (msg.t) {
        case "ok":
          var p = pending.get(msg.id);
          if (p) {
            pending.delete(msg.id);
            p.resolve(msg.v);
          }
          break;
        case "err":
          var q = pending.get(msg.id);
          if (q) {
            pending.delete(msg.id);
            var err = new Error(msg.m || "myzig call failed");
            err.code = msg.c || "error";
            q.reject(err);
          }
          break;
        case "ev":
          emit(msg.e, msg.d);
          break;
        case "chunk":
          // A streamed response: each chunk calls a progress callback the
          // caller passed as an argument.
          var c = pending.get(msg.id);
          if (c && c.onchunk) c.onchunk(msg.d);
          break;
        default:
          break;
      }
    }
  };

  Object.defineProperty(W, "myzig", {
    value: Object.freeze(api),
    writable: false,
    configurable: false,
    enumerable: true
  });

  Object.defineProperty(W, "__myzig", {
    value: Object.freeze({
      receive: receive,
      emit: emit
    }),
    writable: false,
    configurable: false,
    enumerable: false
  });

  // Let the page know the bridge exists before its own scripts run, without
  // racing the framework listener.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      emit("myzig:ready", { windowId: WINDOW_ID, version: VERSION });
    });
  } else {
    emit("myzig:ready", { windowId: WINDOW_ID, version: VERSION });
  }
})();
