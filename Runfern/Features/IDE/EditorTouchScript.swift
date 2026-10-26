import WebKit

/// Touch adaptations for VS Code's web UI, active while the page carries the `runfern-touch`
/// class (set by `IDEWebViewCache`), so they switch on and off without reloading VS Code:
///
/// - larger targets in menus, tabs, and toolbars, no tap highlight or callouts on UI elements,
/// - a long press opens VS Code's context menu where the finger is; in the editor's text it
///   starts a selection that follows the finger, and a double tap selects a word,
/// - `runfernKey(…)` lets the keyboard bar send keys and shortcuts to VS Code.
///
/// The whole workbench is additionally enlarged through the page's viewport, which WebKit honors
/// in its mobile content mode: VS Code lays itself out for a narrower page that is shown
/// enlarged, and touches map to it like in Safari on a phone.
enum EditorTouchScript {
    static let scale = 1.2

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// VS Code settings for touch, handed to the workbench as its defaults before it starts, so the
    /// user's own settings still win and nothing is written to them.
    static let editorDefaults: [String: Any] = [
        "editor.showFoldingControls": "always",
        "editor.wordWrap": "on",
        "editor.lineHeight": 1.6,
        "editor.dragAndDrop": false,
        "editor.scrollbar.verticalScrollbarSize": 18,
        "editor.scrollbar.horizontalScrollbarSize": 18,
        "editor.smoothScrolling": true,
        "editor.hover.delay": 600,
        "workbench.list.smoothScrolling": true,
        "workbench.tree.indent": 16,
        "workbench.secondarySideBar.defaultVisibility": "hidden",
        "explorer.compactFolders": false,
    ]

    /// Puts `editorDefaults` into the workbench configuration the page carries, before VS Code reads it.
    static var defaultsScript: WKUserScript {
        let defaults = (try? JSONSerialization.data(withJSONObject: editorDefaults)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let source = """
        (() => {
          const defaults = \(defaults);
          const patch = (meta) => {
            try {
              const config = JSON.parse(meta.getAttribute("data-settings") || "{}");
              config.configurationDefaults = { ...defaults, ...(config.configurationDefaults || {}) };
              meta.setAttribute("data-settings", JSON.stringify(config));
            } catch (error) {}
          };
          const found = document.getElementById("vscode-workbench-web-configuration");
          if (found) { patch(found); return; }
          const observer = new MutationObserver(() => {
            const meta = document.getElementById("vscode-workbench-web-configuration");
            if (meta) { observer.disconnect(); patch(meta); }
          });
          observer.observe(document, { childList: true, subtree: true });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// The message the page sends when a long press took effect.
    static let hapticMessage = "touch-haptic"

    /// JavaScript that switches the adaptations on or off.
    static func apply(_ enabled: Bool, width: Double) -> String {
        "window.runfernTouch?.(\(enabled), \(Int(width.rounded())), \(scale));"
    }

    /// The message the page sends once the script is in place, so the app can apply the setting.
    static let readyMessage = "touch-ready"

    /// JavaScript that sends `key` to VS Code.
    static func send(_ key: EditorKey) -> String {
        if let text = key.text {
            let literal = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return "window.runfernInsert?.(...\(literal));"
        }
        return "window.runfernKey?.(\(key.script));"
    }

    private static let source = #"""
    (() => {
      const css = `
        html.runfern-touch, html.runfern-touch * { -webkit-tap-highlight-color: transparent; }
        /* The system's scroll indicators show up over VS Code's own scrollbars. */
        html.runfern-touch * { scrollbar-width: none; }
        html.runfern-touch .monaco-workbench .part:not(.editor),
        html.runfern-touch .monaco-workbench .tabs-container,
        html.runfern-touch .monaco-menu-container { -webkit-touch-callout: none; -webkit-user-select: none; }
        html.runfern-touch .monaco-menu .monaco-action-bar.vertical .action-menu-item { height: 2.4em !important; }
        html.runfern-touch .monaco-menu .monaco-action-bar.vertical .action-label:not(.separator),
        html.runfern-touch .monaco-menu .monaco-action-bar.vertical .keybinding { line-height: 2.4em !important; }
        html.runfern-touch .monaco-menu .monaco-action-bar.vertical .submenu-indicator { line-height: 2.4em !important; }
        html.runfern-touch .monaco-workbench .monaco-action-bar .action-item .action-label.codicon { padding: 4px !important; }
        html.runfern-touch .monaco-workbench .tabs-container > .tab .tab-actions .action-label { padding: 4px !important; }
      `;
      const style = document.createElement("style");
      style.id = "runfern-touch-style";
      style.textContent = css;
      document.head.appendChild(style);

      const touchOn = () => document.documentElement.classList.contains("runfern-touch");

      // VS Code lays itself out again on resize, which the page zoom doesn't always announce.
      // VS Code writes its own viewport too, so the wanted one is kept in place.
      let wanted = null;
      const viewports = () => {
        const found = [...document.querySelectorAll('meta[name="viewport"]')];
        if (found.length) { return found; }
        const meta = document.createElement("meta");
        meta.name = "viewport";
        document.head.appendChild(meta);
        return [meta];
      };
      const original = viewports()[0].content || "width=device-width, initial-scale=1.0";
      const enforce = () => {
        const content = wanted ?? original;
        for (const meta of viewports()) {
          if (meta.content !== content) { meta.content = content; }
        }
      };
      new MutationObserver(enforce).observe(document.head, { subtree: true, childList: true, attributes: true, attributeFilter: ["content"] });
      window.runfernTouch = (enabled, width, scale) => {
        document.documentElement.classList.toggle("runfern-touch", enabled);
        wanted = enabled
          ? `width=${Math.round(width / scale)}, initial-scale=${scale}, minimum-scale=${scale}, maximum-scale=${scale}, user-scalable=no`
          : null;
        enforce();
        requestAnimationFrame(() => window.dispatchEvent(new Event("resize")));
      };
      window.webkit?.messageHandlers?.runfern?.postMessage("touch-ready");

      // Long press: VS Code's context menu at the finger, without the system's selection callout.
      // In the editor's text, a long press starts a selection instead that follows the finger;
      // lifting without moving opens the context menu there. A double tap selects the word.
      let timer = null, start = null, fired = false, selecting = false, last = null, lastTap = null;
      const cancel = () => { clearTimeout(timer); timer = null; };
      const inText = (target) => target.closest?.(".monaco-editor .view-lines, .monaco-editor .view-overlays") != null;
      // Monaco ignores touch pointers for selections, so the selection is driven like with a mouse.
      const pointer = (type, target, x, y, buttons, detail = 1) => target.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, pointerId: 1, pointerType: "mouse", isPrimary: true,
        clientX: x, clientY: y, button: 0, buttons, detail
      }));
      const haptic = () => window.webkit?.messageHandlers?.runfern?.postMessage("touch-haptic");
      const contextMenu = (target, x, y) => target.dispatchEvent(new MouseEvent("contextmenu", {
        bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2, buttons: 2
      }));
      document.addEventListener("touchstart", (event) => {
        if (!touchOn()) { return; }
        // A tap outside an open menu closes it, which VS Code leaves to mouse events that touches
        // in the editor don't produce.
        const menu = ".monaco-menu-container, .menubar";
        const open = [...document.querySelectorAll(".monaco-menu-container")].some((element) => element.getClientRects().length);
        if (open && !event.target.closest?.(menu)) {
          document.activeElement?.dispatchEvent(new KeyboardEvent("keydown", {
            key: "Escape", code: "Escape", keyCode: 27, bubbles: true, cancelable: true
          }));
        }
        if (event.touches.length !== 1) { cancel(); return; }
        const touch = event.touches[0];
        start = { x: touch.clientX, y: touch.clientY, target: event.target, text: inText(event.target) };
        last = start;
        fired = false;
        selecting = false;
        cancel();
        timer = setTimeout(() => {
          timer = null;
          fired = true;
          haptic();
          if (start.text) {
            selecting = true;
            pointer("pointerdown", start.target, start.x, start.y, 1);
          } else {
            contextMenu(start.target, start.x, start.y);
          }
        }, 450);
      }, { capture: true, passive: true });
      document.addEventListener("touchmove", (event) => {
        if (!start) { return; }
        const touch = event.touches[0];
        if (selecting) {
          // The finger extends the selection instead of scrolling the editor.
          event.preventDefault();
          event.stopPropagation();
          last = { x: touch.clientX, y: touch.clientY };
          pointer("pointermove", document.elementFromPoint(last.x, last.y) ?? start.target, last.x, last.y, 1);
          return;
        }
        if (timer && Math.hypot(touch.clientX - start.x, touch.clientY - start.y) > 10) { cancel(); }
      }, { capture: true, passive: false });
      for (const type of ["touchend", "touchcancel"]) {
        document.addEventListener(type, (event) => {
          const wasTimer = timer != null;
          cancel();
          if (selecting) {
            selecting = false;
            pointer("pointerup", document.elementFromPoint(last.x, last.y) ?? start.target, last.x, last.y, 0);
            if (Math.hypot(last.x - start.x, last.y - start.y) < 10) { contextMenu(start.target, start.x, start.y); }
          }
          // The finger lifting after the menu opened must not also tap the item below it.
          if (fired) { event.preventDefault(); event.stopPropagation(); fired = false; return; }
          if (type !== "touchend" || !wasTimer || !start?.text) { return; }
          // A second short tap close to the first one selects the word, like a double click.
          const now = Date.now();
          if (lastTap && now - lastTap.time < 350 && Math.hypot(start.x - lastTap.x, start.y - lastTap.y) < 20) {
            lastTap = null;
            const { target, x, y } = start;
            setTimeout(() => {
              pointer("pointerdown", target, x, y, 1, 2);
              pointer("pointerup", target, x, y, 0, 2);
            }, 0);
          } else {
            lastTap = { time: now, x: start.x, y: start.y };
          }
        }, { capture: true });
      }

      // Characters from the keyboard bar, typed into the focused element like from the keyboard,
      // so VS Code's auto-closing brackets and quotes apply.
      window.runfernInsert = (text) => { document.execCommand("insertText", false, text); };

      // Keys from the keyboard bar, delivered like real key presses to the focused element.
      window.runfernKey = ({ key, code, keyCode, meta = false, shift = false, ctrl = false, alt = false }) => {
        const target = document.activeElement ?? document.body;
        for (const type of ["keydown", "keyup"]) {
          const event = new KeyboardEvent(type, {
            key, code, bubbles: true, cancelable: true, composed: true,
            metaKey: meta, shiftKey: shift, ctrlKey: ctrl, altKey: alt
          });
          // Monaco and VS Code's keybindings read the legacy key codes.
          Object.defineProperty(event, "keyCode", { get: () => keyCode });
          Object.defineProperty(event, "which", { get: () => keyCode });
          target.dispatchEvent(event);
        }
      };
    })();
    """#
}

/// A key or shortcut on the keyboard bar.
struct EditorKey: Identifiable, Hashable {
    let id: String
    let title: LocalizedStringResource
    let systemImage: String?
    var key = ""
    var code = ""
    var keyCode = 0
    var meta = false
    var shift = false
    /// Characters the key types instead of sending a key press.
    var text: String?

    static func == (lhs: EditorKey, rhs: EditorKey) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var script: String {
        #"{key:"\#(key)",code:"\#(code)",keyCode:\#(keyCode),meta:\#(meta),shift:\#(shift)}"#
    }

    static let escape = EditorKey(id: "escape", title: "Escape", systemImage: "escape", key: "Escape", code: "Escape", keyCode: 27)
    static let tab = EditorKey(id: "tab", title: "Tab", systemImage: "arrow.right.to.line", key: "Tab", code: "Tab", keyCode: 9)
    static let left = EditorKey(id: "left", title: "Left", systemImage: "arrow.left", key: "ArrowLeft", code: "ArrowLeft", keyCode: 37)
    static let up = EditorKey(id: "up", title: "Up", systemImage: "arrow.up", key: "ArrowUp", code: "ArrowUp", keyCode: 38)
    static let down = EditorKey(id: "down", title: "Down", systemImage: "arrow.down", key: "ArrowDown", code: "ArrowDown", keyCode: 40)
    static let right = EditorKey(id: "right", title: "Right", systemImage: "arrow.right", key: "ArrowRight", code: "ArrowRight", keyCode: 39)
    static let undo = EditorKey(id: "undo", title: "Undo", systemImage: "arrow.uturn.backward", key: "z", code: "KeyZ", keyCode: 90, meta: true)
    static let redo = EditorKey(id: "redo", title: "Redo", systemImage: "arrow.uturn.forward", key: "z", code: "KeyZ", keyCode: 90, meta: true, shift: true)
    static let save = EditorKey(id: "save", title: "Save", systemImage: "square.and.arrow.down", key: "s", code: "KeyS", keyCode: 83, meta: true)
    static let quickOpen = EditorKey(id: "quickOpen", title: "Go to File", systemImage: "doc.text.magnifyingglass", key: "p", code: "KeyP", keyCode: 80, meta: true)
    static let commands = EditorKey(id: "commands", title: "Commands", systemImage: "command", key: "p", code: "KeyP", keyCode: 80, meta: true, shift: true)
    static let find = EditorKey(id: "find", title: "Find", systemImage: "magnifyingglass", key: "f", code: "KeyF", keyCode: 70, meta: true)
    static let symbols = ["(", "{", "[", "\"", "=", ";"].map { text in
        EditorKey(id: "text-\(text)", title: LocalizedStringResource(String.LocalizationValue(text)), systemImage: nil, text: text)
    }
    static let comment = EditorKey(id: "comment", title: "Toggle Comment", systemImage: "number", key: "/", code: "Slash", keyCode: 191, meta: true)
}
