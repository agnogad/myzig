const status = document.getElementById("bridge");
if (window.myzig) {
  status.textContent =
    "Bridge status: connected to window " + window.myzig.windowId +
    " (MyZig " + window.myzig.version + " on " + window.myzig.platform + ")";
} else {
  status.textContent = "Bridge status: running outside MyZig";
}
