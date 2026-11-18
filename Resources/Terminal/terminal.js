// The page side of Gita's built-in terminal. The app sets `window.gitaTerminal` (font and colours) before this runs,
// then calls `gita.write`, `gita.configure` and `gita.focus`; what is typed and the terminal's size go back to the
// app through the `terminal` message handler.
"use strict";
(() => {
  const post = (message) => window.webkit.messageHandlers.terminal.postMessage(message);
  const settings = window.gitaTerminal || {};
  const term = new Terminal({
    fontFamily: settings.fontFamily,
    fontSize: settings.fontSize,
    lineHeight: settings.lineHeight,
    theme: settings.theme,
    scrollback: 10000,
    cursorBlink: false,
    macOptionClickForcesSelection: true,
    allowProposedApi: false,
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(document.getElementById("terminal"));

  // The app's own terminal shortcuts (show the terminal, new terminal) go to its menu, not to the program.
  let passKeys = settings.passKeys || [];
  const isPassed = (event) =>
    passKeys.some(
      (key) =>
        key.code === event.code &&
        key.ctrl === event.ctrlKey &&
        key.alt === event.altKey &&
        key.shift === event.shiftKey &&
        key.meta === event.metaKey,
    );
  term.attachCustomKeyEventHandler((event) => !isPassed(event));

  const refit = () => {
    try {
      fit.fit();
    } catch (error) {
      // Hidden pages have no size yet; the next resize fits them.
    }
  };
  const paint = (theme) => {
    if (theme && theme.background) document.body.style.setProperty("--background", theme.background);
  };
  paint(settings.theme);
  new ResizeObserver(refit).observe(document.getElementById("terminal"));

  term.onData((data) => post({ type: "input", data }));
  term.onBinary((data) => post({ type: "binary", data }));
  term.onResize((size) => post({ type: "resize", cols: size.cols, rows: size.rows }));
  term.onTitleChange((title) => post({ type: "title", title }));

  window.gita = {
    // Output from the program, base64 so any bytes (and split UTF-8 sequences) arrive intact.
    write(encoded) {
      const text = atob(encoded);
      const bytes = new Uint8Array(text.length);
      for (let index = 0; index < text.length; index += 1) bytes[index] = text.charCodeAt(index);
      term.write(bytes);
    },
    configure(options) {
      if (options.fontFamily) term.options.fontFamily = options.fontFamily;
      if (options.fontSize) term.options.fontSize = options.fontSize;
      if (options.lineHeight) term.options.lineHeight = options.lineHeight;
      if (options.theme) term.options.theme = options.theme;
      if (options.passKeys) passKeys = options.passKeys;
      paint(options.theme);
      refit();
    },
    focus() {
      term.focus();
    },
  };

  refit();
  // The keyboard goes to the terminal whenever the app makes the page the first responder.
  term.focus();
  post({ type: "ready", cols: term.cols, rows: term.rows });
})();
