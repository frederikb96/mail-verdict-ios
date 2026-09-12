// The reader page's own script. It runs only in the app's client content world: message pages
// load with page JavaScript switched off, so nothing a message contains ever executes, while this
// file keeps working beside it. Every entry point hangs off `window.mvReader` in that world, and
// the app calls them by name (ReaderScript.Function).
(() => {
  "use strict";

  const bodyHosts = () => Array.from(document.querySelectorAll(".mv-body"));
  const primaryId = () => document.documentElement.dataset.primary;

  // Fixed-width newsletters: a body wider than the page is scaled down with CSS zoom, which is
  // layout zoom and stays crisp, so the page opens fitted at scroll-view zoom 1 and every
  // horizontal drag at rest zoom belongs to the pager.
  function fit(host) {
    host.style.zoom = "";
    const root = host.shadowRoot;
    if (!root) return;
    const hostLeft = host.getBoundingClientRect().left;
    let widest = host.scrollWidth;
    for (const child of Array.from(root.children)) {
      const right = child.getBoundingClientRect().right - hostLeft;
      widest = Math.max(widest, right, child.scrollWidth);
    }
    const available = host.clientWidth;
    if (available > 0 && widest > available + 1) {
      host.style.zoom = String(available / widest);
    }
  }

  function fitAll() {
    bodyHosts().forEach(fit);
  }

  let fitScheduled = false;
  function scheduleFit() {
    if (fitScheduled) return;
    fitScheduled = true;
    requestAnimationFrame(() => {
      fitScheduled = false;
      fitAll();
    });
  }

  // A load inside a shadow root does not reach the document, so each body is watched itself —
  // an image arriving late can make a body wider than it first measured.
  function watch(host) {
    const root = host.shadowRoot;
    if (!root || root.__mvWatched) return;
    root.__mvWatched = true;
    root.addEventListener("load", scheduleFit, true);
  }

  // Find in Message: ranges over the opened message's own text, painted with the Custom
  // Highlight API. Nothing in the document changes, so a search never disturbs layout.
  let ranges = [];

  function clearFind() {
    ranges = [];
    if (globalThis.CSS && CSS.highlights) {
      CSS.highlights.delete("mv-find");
      CSS.highlights.delete("mv-find-active");
    }
  }

  function find(query) {
    clearFind();
    const needle = String(query || "").trim().toLowerCase();
    const host = document.getElementById("mv-body-" + primaryId());
    const root = host && host.shadowRoot;
    if (!needle || !root) return 0;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => {
        const tag = node.parentElement && node.parentElement.tagName;
        return tag === "STYLE" || tag === "SCRIPT" ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      },
    });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = node.textContent.toLowerCase();
      let index = text.indexOf(needle);
      while (index !== -1) {
        const range = new Range();
        range.setStart(node, index);
        range.setEnd(node, index + needle.length);
        ranges.push(range);
        index = text.indexOf(needle, index + needle.length);
      }
    }
    if (ranges.length && globalThis.CSS && CSS.highlights) {
      CSS.highlights.set("mv-find", new Highlight(...ranges));
    }
    return ranges.length;
  }

  function highlight(index) {
    const range = ranges[index];
    if (!range) return false;
    if (globalThis.CSS && CSS.highlights) {
      CSS.highlights.set("mv-find-active", new Highlight(range));
    }
    const element = range.startContainer.parentElement;
    if (element) element.scrollIntoView({ block: "center" });
    return true;
  }

  // Swaps one block for new markup. `setHTMLUnsafe` is used rather than `outerHTML` because it
  // parses declarative shadow roots — a message body block carries one.
  function replaceBlock(id, html) {
    const element = document.getElementById(id);
    if (!element) return false;
    const holder = document.createElement("div");
    holder.setHTMLUnsafe(html);
    const replacement = holder.firstElementChild;
    if (!replacement) return false;
    element.replaceWith(replacement);
    clearFind();
    for (const host of replacement.matches(".mv-body") ? [replacement] : replacement.querySelectorAll(".mv-body")) {
      watch(host);
    }
    scheduleFit();
    return true;
  }

  // Document offsets of the message blocks in CSS pixels, independent of the current scroll —
  // what the app anchors a rebuilt page and positions the opened message by.
  function messageOffsets() {
    return Array.from(document.querySelectorAll(".mv-message")).map((element) => {
      let top = 0;
      for (let node = element; node; node = node.offsetParent) top += node.offsetTop;
      return { id: element.id, top };
    });
  }

  function openMessageIds() {
    return Array.from(document.querySelectorAll("details.mv-message[open]")).map((element) => element.id);
  }

  // A message's own table of contents: its ids live inside a shadow root, which the page's own
  // fragment navigation never looks into.
  function scrollToAnchor(name) {
    for (const host of bodyHosts()) {
      const target = host.shadowRoot && host.shadowRoot.getElementById(name);
      if (target) {
        target.scrollIntoView({ block: "start" });
        return true;
      }
    }
    return false;
  }

  window.mvReader = { fit: fitAll, find, highlight, clearFind, replaceBlock, messageOffsets, openMessageIds, scrollToAnchor };

  bodyHosts().forEach(watch);
  fitAll();
  window.addEventListener("load", scheduleFit);
  window.addEventListener("resize", scheduleFit);
  document.addEventListener("toggle", scheduleFit, true);
})();
