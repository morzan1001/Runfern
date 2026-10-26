import WebKit

/// Script injected into VS Code's web UI: adds a "Runfern" button at the top left of VS Code's
/// title bar that returns to the app, so the full-screen editor always has a touch-friendly way
/// back. Messages arrive in the `runfern` script message handler.
enum EditorBridgeScript {
    static let handlerName = "runfern"

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    // VS Code handles touches with its own gesture recognizer and suppresses the synthesized
    // `click`, so the button reacts to the pointer directly.
    private static let source = #"""
    (() => {
      const id = "runfern-back";
      const send = (action) => window.webkit?.messageHandlers?.runfern?.postMessage(action);

      function makeButton() {
        const button = document.createElement("div");
        button.id = id;
        button.setAttribute("role", "button");
        button.setAttribute("aria-label", "Runfern");
        button.title = "Runfern";
        button.innerHTML = '<span class="codicon codicon-arrow-left"></span><span>Runfern</span>';
        Object.assign(button.style, {
          display: "flex", alignItems: "center", gap: "4px", height: "100%", padding: "0 10px",
          cursor: "pointer", fontSize: "13px", whiteSpace: "nowrap", pointerEvents: "auto",
          webkitAppRegion: "no-drag", zIndex: "10"
        });
        let last = 0;
        const activate = (event) => {
          event.preventDefault();
          event.stopPropagation();
          if (Date.now() - last < 500) { return; }
          last = Date.now();
          send("overview");
        };
        for (const type of ["pointerup", "touchend", "click"]) {
          button.addEventListener(type, activate, { capture: true });
        }
        for (const type of ["pointerdown", "touchstart", "mousedown"]) {
          button.addEventListener(type, (event) => event.stopPropagation(), { capture: true });
        }
        return button;
      }

      function install() {
        const host = document.querySelector(".part.titlebar .titlebar-left")
          ?? document.querySelector(".part.statusbar .left-items");
        if (!host) { return; }
        const existing = document.getElementById(id);
        if (existing && existing.parentElement === host && host.firstChild === existing) { return; }
        host.insertBefore(existing ?? makeButton(), host.firstChild);
      }

      new MutationObserver(install).observe(document.documentElement, { childList: true, subtree: true });
      install();
    })();
    """#
}
