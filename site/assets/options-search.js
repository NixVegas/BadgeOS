// The options search page: filters the option list in options/search-index.js.
(function () {
  "use strict";

  const root = document.getElementById("options-search");
  if (!root) {
    return;
  }

  const input = document.getElementById("options-search-input");
  const status = document.getElementById("options-search-status");
  const results = document.getElementById("options-search-results");
  // mdBook defines path_to_root on every page.
  const base = typeof path_to_root === "string" ? path_to_root : "";
  const maxShown = 100;
  let options = [];

  // Arrow keys and "?" edit the query instead of turning mdBook's pages.
  input.addEventListener("keydown", (event) => event.stopPropagation());

  function words(query) {
    return query.toLowerCase().split(/\s+/).filter(Boolean);
  }

  // 0 when a word is missing; name matches weigh more than description matches.
  function score(option, terms) {
    const name = option.name.toLowerCase();
    const text = option.description.toLowerCase();
    let total = 0;
    for (const term of terms) {
      if (name.endsWith("." + term)) {
        total += 20;
      } else if (name.includes(term)) {
        total += 10;
      } else if (text.includes(term)) {
        total += 1;
      } else {
        return 0;
      }
    }
    return total;
  }

  // The first paragraph, on one line, cut at about 300 characters.
  function summary(description) {
    const first = description.split(/\n\s*\n/)[0].replace(/\s+/g, " ").trim();
    return first.length > 300 ? first.slice(0, 297).trimEnd() + "…" : first;
  }

  // Text with `code` spans, without interpreting any other markup.
  function appendText(parent, text) {
    text.split("`").forEach((part, index) => {
      if (index % 2 === 1) {
        const code = document.createElement("code");
        code.textContent = part;
        parent.appendChild(code);
      } else if (part) {
        parent.appendChild(document.createTextNode(part));
      }
    });
  }

  function entry(option) {
    const item = document.createElement("li");

    const link = document.createElement("a");
    link.className = "options-search-name";
    link.href = base + option.page + "#" + option.anchor;
    const name = document.createElement("code");
    name.textContent = option.name;
    link.appendChild(name);
    item.appendChild(link);

    if (option.description) {
      const description = document.createElement("p");
      appendText(description, summary(option.description));
      item.appendChild(description);
    }

    const meta = document.createElement("p");
    meta.className = "options-search-meta";
    meta.textContent = "Type: " + option.type;
    if (option.default !== null) {
      meta.append(" · Default: ");
      const value = document.createElement("code");
      value.textContent = option.default.trim();
      meta.appendChild(value);
    }
    item.appendChild(meta);

    return item;
  }

  function render() {
    const terms = words(input.value);
    let matches = options;
    if (terms.length > 0) {
      matches = options
        .map((option) => [score(option, terms), option])
        .filter(([points]) => points > 0)
        .sort((a, b) => b[0] - a[0] || a[1].name.localeCompare(b[1].name))
        .map(([, option]) => option);
    }

    if (terms.length === 0) {
      status.textContent = options.length + " options.";
    } else if (matches.length === 0) {
      status.textContent = "No options match.";
    } else if (matches.length > maxShown) {
      status.textContent = "Showing " + maxShown + " of " + matches.length + " matching options.";
    } else {
      status.textContent = matches.length + (matches.length === 1 ? " option matches." : " options match.");
    }

    results.replaceChildren(...matches.slice(0, maxShown).map(entry));
  }

  // The query lives in ?q= so a search can be shared as a link.
  input.value = new URLSearchParams(window.location.search).get("q") || "";
  input.addEventListener("input", () => {
    const url = new URL(window.location.href);
    if (input.value) {
      url.searchParams.set("q", input.value);
    } else {
      url.searchParams.delete("q");
    }
    window.history.replaceState(null, "", url);
    render();
  });

  // A script rather than a fetch, so the page also works from file://.
  const data = document.createElement("script");
  data.src = base + "options/search-index.js";
  data.onload = () => {
    options = window.badgeosOptions || [];
    render();
  };
  data.onerror = () => {
    status.textContent = "The option list could not be loaded.";
  };
  document.head.appendChild(data);
})();
