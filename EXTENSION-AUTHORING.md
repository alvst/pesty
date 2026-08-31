# Extension authoring cookbook

This cookbook is organized around the kind of extension you want to build.
For the normative API contract, complete limits, trust model, and runtime
semantics, see [EXTENSIONS.md](EXTENSIONS.md).

## Quick start

Every extension is one JavaScript snippet that calls `pesty.register` exactly
once. This is a complete extension:

```javascript
pesty.register({
  id: "com.example.quick-character-count",
  name: "Quick Character Count",
  version: "1.0",
  api: 1,
  types: ["text"],
  badge: function (clip) {
    return clip.text.length === 0 ? null : clip.text.length + " chars";
  }
});
```

Open **Settings → Extensions**, paste the whole snippet into the editor, choose
**Install Extension**, and enable the newly installed row. New extensions are
off by default so that pasted code never starts running without a separate
choice.

Each hook receives one object:

- `clip.type` is one of `text`, `richText`, `link`, `image`, `file`, or `color`.
- `clip.text` is that clip's bounded text, capped at 65,536 UTF-16 code units.
- `config` contains the extension's effective declared settings and is readable
  only inside hook functions.

The host provides no network, file, process, browser, clipboard-history, clip
ID, timestamp, or source-application API. A script load gets 0.5 seconds; each
card or keyword hook gets 0.1 seconds, while `transform` gets 0.25 seconds.
Five consecutive exception failures quarantine and disable an extension, and
any timeout does so immediately. Switch the extension on again to clear that
state.

## Badges

Use `badge: function (clip)` for short facts on a card footer. Return a string
or `null`; output is trimmed, stripped of controls and newlines, and capped at
24 characters. All available badges render in descending `weight` order, so a
badge should be compact even when it is not the only one installed.

### Word count

```javascript
pesty.register({
  id: "com.example.word-count",
  name: "Word Count",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  badge: function (clip) {
    var text = clip.text.trim();
    if (text.length === 0) {
      return null;
    }
    return text.split(/\s+/).length + " words";
  }
});
```

### Line count

```javascript
pesty.register({
  id: "com.example.line-count",
  name: "Line Count",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  badge: function (clip) {
    if (clip.text.length === 0) {
      return null;
    }
    var count = clip.text.split(/\r\n|\r|\n/).length;
    return count + (count === 1 ? " line" : " lines");
  }
});
```

### SHOUTY-text detector

```javascript
pesty.register({
  id: "com.example.shouty-text",
  name: "SHOUTY Text",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  badge: function (clip) {
    var letters = clip.text.match(/[A-Za-z]/g);
    if (letters === null || letters.length < 8) {
      return null;
    }
    var uppercase = clip.text.match(/[A-Z]/g) || [];
    return uppercase.length / letters.length >= 0.8 ? "SHOUTY" : null;
  }
});
```

## Derived categories

Use `label: function (clip)` to replace the built-in type label with a display
string capped at 16 characters. Pair it with `icon: function (clip)`, which
must return a real lowercase SF Symbol name of at most 64 characters, and
optionally `color: function (clip)`, which must return exactly `#RRGGBB`.
`title: function (clip)` may supply a title capped at 60 characters, although a
user-edited title still wins. For each of these single-value decorations, the
first usable result in descending `weight` order wins; an invalid SF Symbol is
skipped.

### Email addresses

```javascript
function containsEmail(text) {
  return /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i.test(text);
}

pesty.register({
  id: "com.example.email-category",
  name: "Email Category",
  version: "1.0",
  api: 1,
  weight: 20,
  types: ["text", "richText"],
  label: function (clip) {
    return containsEmail(clip.text) ? "Email" : null;
  },
  icon: function (clip) {
    return containsEmail(clip.text) ? "envelope.fill" : null;
  }
});
```

### UUIDs

```javascript
function isUUID(text) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(text.trim());
}

pesty.register({
  id: "com.example.uuid-category",
  name: "UUID Category",
  version: "1.0",
  api: 1,
  weight: 10,
  types: ["text"],
  label: function (clip) {
    return isUUID(clip.text) ? "UUID" : null;
  },
  icon: function (clip) {
    return isUUID(clip.text) ? "number.square.fill" : null;
  }
});
```

### Possible secrets

This heuristic looks for a long, whitespace-free value with several character
classes and many distinct characters. It can produce false positives. More
importantly, it labels a clip only **after Pesty-Alvie has stored it**; an
extension cannot block capture or turn ordinary content into concealed data.

```javascript
function looksHighEntropy(text) {
  var value = text.trim();
  if (value.length < 24 || value.length > 200 || /\s/.test(value)) {
    return false;
  }
  var classes = 0;
  if (/[a-z]/.test(value)) { classes += 1; }
  if (/[A-Z]/.test(value)) { classes += 1; }
  if (/[0-9]/.test(value)) { classes += 1; }
  if (/[^A-Za-z0-9]/.test(value)) { classes += 1; }
  var seen = {};
  for (var i = 0; i < value.length; i += 1) {
    seen[value.charAt(i)] = true;
  }
  return classes >= 3 && Object.keys(seen).length / value.length >= 0.55;
}

pesty.register({
  id: "com.example.possible-secret",
  name: "Possible Secret Warning",
  version: "1.0",
  api: 1,
  weight: 100,
  types: ["text"],
  label: function (clip) {
    return looksHighEntropy(clip.text) ? "Possible secret" : null;
  },
  icon: function (clip) {
    return looksHighEntropy(clip.text) ? "exclamationmark.triangle.fill" : null;
  },
  color: function (clip) {
    return looksHighEntropy(clip.text) ? "#B00020" : null;
  }
});
```

## Subtitles

Use `subtitle: function (clip)` for a secondary footer line. Return a display
string or `null`; it is trimmed, stripped of controls and newlines, and capped
at 80 characters. Multiple subtitles aggregate in descending `weight` order,
separated by ` · `, so avoid returning prose that needs several lines.

### URL host and path depth

Bare JavaScriptCore does not provide the browser `URL` class, so this example
parses the narrow `http`/`https` shape it accepts.

```javascript
pesty.register({
  id: "com.example.url-summary",
  name: "URL Summary",
  version: "1.0",
  api: 1,
  types: ["link"],
  subtitle: function (clip) {
    var match = clip.text.trim().match(/^https?:\/\/([^\/?#]+)([^?#]*)/i);
    if (match === null) {
      return null;
    }
    var parts = match[2].split("/").filter(function (part) {
      return part.length > 0;
    });
    var depth = parts.length;
    return match[1].toLowerCase().slice(0, 48) + " · " + depth +
      (depth === 1 ? " path level" : " path levels");
  }
});
```

### Simple CSV shape

This intentionally handles simple comma-separated text, not quoted commas or
embedded newlines. Use a dedicated parser outside the extension system when
full CSV semantics matter.

```javascript
pesty.register({
  id: "com.example.csv-shape",
  name: "CSV Shape",
  version: "1.0",
  api: 1,
  types: ["text"],
  subtitle: function (clip) {
    var text = clip.text.trim();
    if (text.length === 0 || text.indexOf(",") === -1) {
      return null;
    }
    var rows = text.split(/\r\n|\r|\n/).filter(function (row) {
      return row.length > 0;
    });
    if (rows.length === 0) {
      return null;
    }
    return rows.length + " rows × " + rows[0].split(",").length + " cols";
  }
});
```

## Titles

Use `title: function (clip)` to replace Pesty-Alvie's generated display title.
Return a display string or `null`; it is trimmed, stripped of controls and
newlines, and capped at 60 characters. The first usable result in descending
`weight` order wins, but a title explicitly set by the user always takes
precedence.

### First Markdown heading

```javascript
pesty.register({
  id: "com.example.markdown-heading-title",
  name: "Markdown Heading Title",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  title: function (clip) {
    var match = clip.text.match(/^\s{0,3}#{1,6}\s+(.+)$/m);
    if (match === null) {
      return null;
    }
    return match[1].replace(/\s+#+\s*$/, "").trim();
  }
});
```

### First JSON object key

```javascript
pesty.register({
  id: "com.example.json-first-key-title",
  name: "JSON First Key Title",
  version: "1.0",
  api: 1,
  types: ["text"],
  title: function (clip) {
    try {
      var value = JSON.parse(clip.text);
      if (value === null || Array.isArray(value) || typeof value !== "object") {
        return null;
      }
      var keys = Object.keys(value);
      return keys.length === 0 ? null : "JSON · " + keys[0];
    } catch (error) {
      return null;
    }
  }
});
```

## Transform paste

Use `transform: function (clip)` to produce explicit paste or copy output.
Return a string or `null`; content is preserved exactly but rejected above
1,048,576 UTF-16 code units. A transform never runs automatically: Pesty-Alvie
adds **Paste via Extension Name**, and a `copyTransformed` menu item can expose
the same hook as a copy action. An exception, timeout, non-string, over-limit
value, `null`, `undefined`, or empty string is a no-op that leaves the
pasteboard untouched.

### Remove tracking parameters

This example removes `utm_*`, `fbclid`, `gclid`, `mc_cid`, and `mc_eid` query
parameters while preserving other parameters and the fragment.

```javascript
function withoutTrackingParameters(text) {
  var value = text.trim();
  if (!/^https?:\/\//i.test(value)) {
    return null;
  }
  var hashIndex = value.indexOf("#");
  var fragment = hashIndex === -1 ? "" : value.slice(hashIndex);
  var beforeFragment = hashIndex === -1 ? value : value.slice(0, hashIndex);
  var queryIndex = beforeFragment.indexOf("?");
  if (queryIndex === -1) {
    return null;
  }
  var removed = false;
  var kept = beforeFragment.slice(queryIndex + 1).split("&").filter(function (pair) {
    if (pair.length === 0) {
      return false;
    }
    var key = pair.split("=")[0];
    try {
      key = decodeURIComponent(key);
    } catch (error) {
      return true;
    }
    key = key.toLowerCase();
    var tracking = key.indexOf("utm_") === 0 ||
      ["fbclid", "gclid", "mc_cid", "mc_eid"].indexOf(key) !== -1;
    if (tracking) {
      removed = true;
    }
    return !tracking;
  });
  if (!removed) {
    return null;
  }
  return beforeFragment.slice(0, queryIndex) +
    (kept.length === 0 ? "" : "?" + kept.join("&")) + fragment;
}

pesty.register({
  id: "com.example.utm-strip",
  name: "Tracking Parameter Stripper",
  version: "1.0",
  api: 1,
  types: ["link", "text"],
  menuItems: [
    { title: "Copy without tracking", verb: "copyTransformed" }
  ],
  transform: function (clip) {
    return withoutTrackingParameters(clip.text);
  }
});
```

### Pretty-print JSON

```javascript
pesty.register({
  id: "com.example.pretty-json",
  name: "Pretty JSON",
  version: "1.0",
  api: 1,
  types: ["text"],
  transform: function (clip) {
    try {
      var pretty = JSON.stringify(JSON.parse(clip.text), null, 2);
      return pretty === clip.text ? null : pretty;
    } catch (error) {
      return null;
    }
  }
});
```

### Curly quotes to straight quotes

```javascript
pesty.register({
  id: "com.example.straight-quotes",
  name: "Straight Quotes",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  transform: function (clip) {
    var straight = clip.text
      .replace(/[“”]/g, "\"")
      .replace(/[‘’]/g, "'");
    return straight === clip.text ? null : straight;
  }
});
```

## Menu actions

Declare `menuItems` to add up to three explicit actions to an ordinary clip's
context menu. Each item has a display-sanitized `title` capped at 30 characters
and one fixed verb: `copyTransformed` or `revealInFinder`. A
`copyTransformed` item requires a `transform` hook; `revealInFinder` appears
only for file clips with stored file URLs. `openURL` is intentionally excluded
because opening an extension-constructed URL could exfiltrate clip content.

The tracking-parameter example above demonstrates the standard
`copyTransformed` pairing. Here is another complete pairing:

```javascript
pesty.register({
  id: "com.example.copy-single-spaced",
  name: "Single-Spaced Copy",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  menuItems: [
    { title: "Copy single-spaced", verb: "copyTransformed" }
  ],
  transform: function (clip) {
    var normalized = clip.text.trim().replace(/\s+/g, " ");
    if (normalized.length === 0 || normalized === clip.text) {
      return null;
    }
    return normalized;
  }
});
```

The reveal verb does not run extension JavaScript to discover paths;
Pesty-Alvie validates and reveals the file URLs already stored on the clip.
Because a manifest still needs at least one hook, this example also supplies a
file label:

```javascript
pesty.register({
  id: "com.example.reveal-files",
  name: "Reveal Files",
  version: "1.0",
  api: 1,
  types: ["file"],
  menuItems: [
    { title: "Reveal selected files", verb: "revealInFinder" }
  ],
  label: function (clip) {
    return "Files";
  }
});
```

## Pinboard suggestions

Use `suggestPinboard: function (clip)` to return an existing Pinboard's display
name or `null`. The string receives display sanitation and a 40-character cap.
The first usable suggestion in descending `weight` order may add an explicit
**Add to Board — Suggested** action; it never creates a board or files the clip
automatically. Matching ignores case and surrounding whitespace, and no action
appears if the named board does not exist or already contains the clip.

### Send links to a Links board

```javascript
pesty.register({
  id: "com.example.suggest-links",
  name: "Suggest Links Board",
  version: "1.0",
  api: 1,
  types: ["link"],
  suggestPinboard: function (clip) {
    return "Links";
  }
});
```

### Send code-looking text to a Snippets board

```javascript
function looksLikeCode(text) {
  var signals = 0;
  if (/\b(function|class|const|let|var|import|def)\b/.test(text)) {
    signals += 1;
  }
  if (/[{};]/.test(text)) {
    signals += 1;
  }
  if (/=>|\([^)]*\)\s*\{/.test(text)) {
    signals += 1;
  }
  return signals >= 2;
}

pesty.register({
  id: "com.example.suggest-snippets",
  name: "Suggest Snippets Board",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  suggestPinboard: function (clip) {
    return looksLikeCode(clip.text) ? "Snippets" : null;
  }
});
```

## Search keywords

Use `keywords: function (clip)` to return an array of strings or `null`. The
host drops non-string entries, trims and strips controls/newlines, lowercases,
deduplicates, caps each keyword at 32 characters, and retains at most 32.
Keywords do not decorate a card: a background sweep evaluates each missing
clip/extension pair, persists the results, and ORs substring matches into the
main History and Pinboard search.

### Index email-like text

```javascript
pesty.register({
  id: "com.example.email-keywords",
  name: "Email Keywords",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  keywords: function (clip) {
    var email = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i.test(clip.text);
    return email ? ["email", "address"] : null;
  }
});
```

### Index a URL by host

```javascript
pesty.register({
  id: "com.example.url-host-keyword",
  name: "URL Host Keyword",
  version: "1.0",
  api: 1,
  types: ["link"],
  keywords: function (clip) {
    var match = clip.text.trim().match(/^https?:\/\/([^\/?#]+)/i);
    if (match === null) {
      return null;
    }
    return [match[1].toLowerCase().replace(/:\d+$/, "")];
  }
});
```

## Configurable extensions

Declare up to eight `config` fields. Pesty-Alvie validates and stores their
values, renders controls in the Extensions pane, and exposes the effective
values through the global `config` object while a hook is running. Never read
`config` at script top level: it does not exist during installation validation.

| Field type | Value and control |
| --- | --- |
| `boolean` | Boolean displayed as a toggle |
| `number` | Finite number displayed as a number field |
| `string` | String of at most 200 characters displayed as text |
| `choice` | String selected from 2-10 declared unique options, each at most 30 characters |

Keys use 1-32 lowercase ASCII letters, digits, underscores, or hyphens. Labels
are capped at 40 characters, and every field needs a correctly typed default.
A settings change invalidates cached results before the extension runs again.

### Configurable word count

```javascript
function configuredWordCount(text) {
  var trimmed = text.trim();
  return trimmed.length === 0 ? 0 : trimmed.split(/\s+/).length;
}

pesty.register({
  id: "com.example.configurable-word-count",
  name: "Configurable Word Count",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  config: [
    { key: "minimum", type: "number", label: "Minimum words", default: 1 },
    { key: "show_detail", type: "boolean", label: "Show detail", default: true }
  ],
  badge: function (clip) {
    var count = configuredWordCount(clip.text);
    var minimum = Math.max(0, config.minimum);
    return count >= minimum && count > 0 ? count + " words" : null;
  },
  subtitle: function (clip) {
    if (!config.show_detail) {
      return null;
    }
    var count = configuredWordCount(clip.text);
    return count === 0 ? null : "Configured minimum: " + Math.max(0, config.minimum);
  }
});
```

### Configurable quote style

```javascript
function straightQuoteStyle(text) {
  return text.replace(/[“”]/g, "\"").replace(/[‘’]/g, "'");
}

function curlyQuoteStyle(text) {
  return text
    .replace(/"([^"\n]+)"/g, "“$1”")
    .replace(/'([^'\n]+)'/g, "‘$1’");
}

pesty.register({
  id: "com.example.configurable-quotes",
  name: "Configurable Quotes",
  version: "1.0",
  api: 1,
  types: ["text", "richText"],
  config: [
    {
      key: "style",
      type: "choice",
      label: "Quote style",
      default: "straight",
      options: ["straight", "curly"]
    }
  ],
  menuItems: [
    { title: "Copy with quote style", verb: "copyTransformed" }
  ],
  transform: function (clip) {
    var result = config.style === "curly"
      ? curlyQuoteStyle(clip.text)
      : straightQuoteStyle(clip.text);
    return result === clip.text ? null : result;
  }
});
```

## Combining hooks

One extension may combine types, configuration, weight, card decorations,
search keywords, and an explicit transform. Card-decoration hooks in one
evaluation share a context, but each should still compute a correct result
without relying on another hook having run first.

This Markdown helper recognizes common Markdown shapes, labels and indexes the
clip, promotes its first heading to a title, optionally adds a word-count
badge, and offers a plain-text transform:

```javascript
function markdownInfo(text) {
  var heading = text.match(/^\s{0,3}#{1,6}\s+(.+)$/m);
  var markdown = heading !== null ||
    /\[[^\]]+\]\([^)]+\)/.test(text) ||
    /^\s*[-+*]\s+/m.test(text) ||
    /(?:\*\*|__)[^\n]+(?:\*\*|__)/.test(text);
  if (!markdown) {
    return null;
  }
  var plainWords = text
    .replace(/[`*_~#>\[\]()]/g, " ")
    .trim();
  return {
    heading: heading === null ? null : heading[1].replace(/\s+#+\s*$/, "").trim(),
    words: plainWords.length === 0 ? 0 : plainWords.split(/\s+/).length
  };
}

function markdownAsPlainText(text) {
  return text
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/^\s*[-+*]\s+/gm, "")
    .replace(/[`*_~]/g, "")
    .trim();
}

pesty.register({
  id: "com.example.markdown-helper",
  name: "Markdown Helper",
  version: "1.0",
  api: 1,
  weight: 25,
  types: ["text", "richText"],
  config: [
    {
      key: "show_word_count",
      type: "boolean",
      label: "Show word count",
      default: true
    },
    {
      key: "minimum_words",
      type: "number",
      label: "Minimum words",
      default: 1
    }
  ],
  menuItems: [
    { title: "Copy plain Markdown", verb: "copyTransformed" }
  ],
  label: function (clip) {
    return markdownInfo(clip.text) === null ? null : "Markdown";
  },
  icon: function (clip) {
    return markdownInfo(clip.text) === null ? null : "doc.text";
  },
  title: function (clip) {
    var info = markdownInfo(clip.text);
    return info === null ? null : info.heading;
  },
  badge: function (clip) {
    var info = markdownInfo(clip.text);
    if (info === null || !config.show_word_count ||
        info.words < Math.max(0, config.minimum_words)) {
      return null;
    }
    return info.words + " words";
  },
  transform: function (clip) {
    if (markdownInfo(clip.text) === null) {
      return null;
    }
    var plain = markdownAsPlainText(clip.text);
    return plain.length === 0 || plain === clip.text ? null : plain;
  },
  keywords: function (clip) {
    return markdownInfo(clip.text) === null ? null : ["markdown"];
  }
});
```

## Testing your extension

Installing a pasted script is the first validation pass. Pesty-Alvie evaluates
the top level with the 0.5-second load budget and rejects missing or duplicate
`pesty.register` calls, malformed manifest fields, non-function hooks, and
unsupported API versions before saving anything.

After enabling the extension, try representative matching, non-matching,
empty, and near-limit clips. A display hook should return `null` for content it
does not recognize; a transform should return `null` when it has no useful
change. Confirm any configured defaults, type restrictions, menu visibility,
and Pinboard-name assumptions in the UI.

Script exception messages shown by the app are capped at 200 characters. Five
consecutive exception failures produce a quarantine warning and disable the
row; a timeout does so immediately. Fix or reinstall the source as needed, then
switch the row on again to clear the quarantine and retry. The warning states
whether the extension timed out or failed repeatedly. Pesty-Alvie also posts
one matching local notification when quarantine begins; macOS asks permission
only when the first such alert is needed, so test both the allowed and denied
permission paths without expecting a prompt at launch.
