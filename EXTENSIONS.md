# Pesty-Alvie extensions

Pesty-Alvie extensions are JavaScript snippets that synchronously derive clip-card
decorations or provide an explicit transformed-paste action. API 1 supports seven
hooks: `badge`, `subtitle`, `icon`, `color`, `title`, `label`, and `transform`.
Extensions cannot mutate stored clips, paste automatically, add settings, run
commands, or observe clipboard history.

Extensions are currently available only in the Mac app.

## Trust and execution model

The extension host exposes `pesty.register` to a JavaScriptCore context. It does
not expose network or file APIs. Browser and Node.js APIs such as `fetch`,
`XMLHttpRequest`, `require`, and `process` are not available.

The only clip content passed to an extension is the bounded text of the single
clip being evaluated. The input also includes that clip's non-content type
string. It does not include clipboard history, other clips, source-app details,
clip IDs, timestamps, image data, or rich-text data. Clips marked concealed or
transient are rejected during capture, so they never reach an extension.

Each evaluation uses a fresh JavaScriptCore virtual machine. An extension does
not share a context or virtual machine with another extension, and contexts are
not reused after an evaluation. The declared card-decoration hooks for one
extension and clip share that evaluation's context; a transform uses a separate
evaluation. Extension work runs off the main thread.

This is a deliberately narrow host surface, not a hardened sandbox for
untrusted code. Pasted scripts still execute inside the Pesty-Alvie process.
Extensions are off by default; install and enable only code that you have read
and trust.

### Timeouts, failures, and quarantine

Loading a script has a 0.5-second budget. Each card-decoration hook has a
separate 0.1-second call budget after loading succeeds. A transform has a
0.25-second call budget.

If one card-decoration hook throws a JavaScript exception, its value is omitted
while values from the other hooks in that evaluation are retained. The
evaluation records one failure tick toward quarantine. A transform exception
produces no transformed paste and also records a failure tick. Five consecutive
failure ticks quarantine and persistently disable the extension; an evaluation
with no failure resets the count. Returning `null`, `undefined`, a non-string,
or an empty display value is a successful no-result, not an exception.

Any load or hook timeout immediately quarantines and persistently disables the
installed extension. Re-enabling the extension in Settings clears its
quarantine and persisted auto-disable state.

JavaScriptCore's public API cannot terminate a script that is already running.
On timeout, Pesty-Alvie stops waiting, abandons the worker thread, and disables
the extension. The script may continue consuming that thread and CPU until it
returns or Pesty-Alvie exits. This is a known limitation of API 1.

## API 1 contract

An extension must call `pesty.register` exactly once while its source is loaded.
The call takes one object with manifest fields and at least one supported hook:

```javascript
pesty.register({
  id: "com.example.word-count",
  name: "Word Count",
  version: "1.0",
  api: 1,
  weight: 5,
  types: ["text", "richText"],
  badge: function (clip) {
    if (clip.text.length === 0) {
      return null;
    }
    return clip.text.trim().split(/\s+/).length + " words";
  }
});
```

The registration fields are:

- `id`: the extension's stable identifier.
- `name`: the display name shown in Settings and transformed-paste menus.
- `version`: the extension author's version string.
- `api`: the Pesty-Alvie extension API version. API 1 requires the integer
  `1`.
- `weight`: an optional finite number used to prioritize card decorations.
  It defaults to `0` and is clamped to `-1000...1000`.
- `types`: an optional non-empty array containing any of `text`, `richText`,
  `link`, `image`, `file`, and `color`. If omitted, the extension supports all
  clip types. Unknown or non-string entries reject the manifest; duplicate
  entries are ignored.
- One or more supported hook functions: `badge`, `subtitle`, `icon`, `color`,
  `title`, `label`, or `transform`. A present hook must be a function.

The clip object passed to every hook has this shape:

```javascript
{
  type: "text", // text, richText, link, image, file, or color
  text: "The bounded text for this clip"
}
```

Pesty-Alvie checks `types` before loading the script for a clip. A type mismatch
short-circuits the evaluation before any extension JavaScript executes.

### Hook signatures, results, and rendering

Every hook has the synchronous signature `function (clip)`. A string is the
only value that can produce output. `null`, `undefined`, every other non-string
value, and Promises produce no output.

Display strings from `badge`, `subtitle`, `title`, and `label` are trimmed,
stripped of control and newline characters, and then capped. A sanitized empty
string produces no output.

| Hook | Accepted string and sanitation | Rendering or action |
| --- | --- | --- |
| `badge(clip)` | Display string capped at 24 characters | All badge results appear in weight order on the card footer's decoration row, separated by ` · `. |
| `subtitle(clip)` | Display string capped at 80 characters | All subtitle results appear in weight order on the footer's secondary line, separated by ` · `. |
| `icon(clip)` | Trimmed SF Symbol name, 1-64 characters, containing only lowercase ASCII letters, digits, and dots | The first valid SF Symbol in weight order appears beside the footer badges. An unknown symbol is skipped. |
| `color(clip)` | Exactly `#RRGGBB`; hexadecimal digits are normalized to uppercase | The first color in weight order replaces the card header color, with the normal readability adjustment applied. |
| `title(clip)` | Display string capped at 60 characters | The first title in weight order overrides the generated display title used by link previews and file-preview captions. A title explicitly set by the user still wins. |
| `label(clip)` | Display string capped at 16 characters | The first label in weight order replaces the built-in clip-type label in the card header. |
| `transform(clip)` | Content is preserved exactly and must not exceed 1,048,576 UTF-16 code units | Adds `Paste via <Extension Name>` to an ordinary clip card's context menu. The returned string is pasted as plain text. |

For card decorations, higher `weight` values are considered first; equal
weights retain catalog order. Badges and subtitles aggregate all available
values in that order. Icon, color, title, and label use the first usable value.
Weight does not reorder transformed-paste menu actions, which retain catalog
order.

## Derived Categories

Extensions can derive a more specific category from clip text without changing
the stored clip type. The general pattern uses `label` for the category name and
can reinforce it with `icon`, `color`, and `title`. Each hook remains
independent: an extension can apply only the pieces that improve the card and
return `null` when the text does not match. A `subtitle` can explain why the
category was detected.

The bundled JSON Detector is the worked example. It classifies text as JSON,
uses `label` and `icon` to present that category, and uses `subtitle` for a
bounded structural summary. It deliberately leaves the header color and
content title unchanged; another derived-category extension can add `color`
and `title` hooks using the same detection function.

```javascript
function pestyJSONInfo(clip) {
  try {
    var value = JSON.parse(clip.text);
    if (Array.isArray(value)) {
      return { subtitle: "Valid JSON · " + value.length + " items" };
    }
    if (value !== null && typeof value === "object") {
      return { subtitle: "Valid JSON · " + Object.keys(value).length + " keys" };
    }
    return { subtitle: "Valid JSON" };
  } catch (error) {
    return null;
  }
}

pesty.register({
  id: "com.alvst.pesty-alvie.json-detector",
  name: "JSON",
  version: "1.0",
  api: 1,
  types: ["text"],
  weight: 10,
  label: function (clip) {
    return pestyJSONInfo(clip) === null ? null : "JSON";
  },
  icon: function (clip) {
    return pestyJSONInfo(clip) === null ? null : "curlybraces";
  },
  subtitle: function (clip) {
    var info = pestyJSONInfo(clip);
    return info === null ? null : info.subtitle;
  }
});
```

## Transform paste semantics

A `transform` hook never runs automatically. For each enabled,
non-quarantined transform extension that supports the clip type, an ordinary
clip card's context menu includes `Paste via <Extension Name>`. Transform
actions are not added to cards inside the Paste Stack deck.

Choosing the action evaluates the hook with the same bounded clip input used by
the decoration hooks. A returned string within the 1,048,576-UTF-16-unit cap is
pasted into the previously active app as plain text. The transform does not
modify or promote the stored clip. A thrown exception, timeout, non-string,
over-cap result, `null`, `undefined`, or empty string pastes nothing and leaves
the pasteboard untouched. The transform call has a 0.25-second budget; a
timeout immediately quarantines the extension.

## Limits

| Surface | API 1 limit |
| --- | --- |
| `pesty.register` | Exactly one call per script load |
| `id` | String; 3-64 ASCII letters, digits, dots, or hyphens; must contain at least one letter |
| `name` | Non-empty string after trimming whitespace; at most 40 characters |
| `version` | Non-empty string after trimming whitespace; at most 16 characters |
| `api` | Integer equal to `1` |
| `weight` | Optional finite number; defaults to `0`; clamped to `-1000...1000` |
| `types` | Optional non-empty array of supported clip-type strings; duplicates are ignored |
| Hooks | At least one of `badge`, `subtitle`, `icon`, `color`, `title`, `label`, or `transform`; each declared value must be a function |
| `clip.type` | One of `text`, `richText`, `link`, `image`, `file`, or `color` |
| `clip.text` | At most 65,536 UTF-16 code units |
| Badge string | Display sanitation, then at most 24 characters |
| Subtitle string | Display sanitation, then at most 80 characters |
| Title string | Display sanitation, then at most 60 characters |
| Label string | Display sanitation, then at most 16 characters |
| Icon string | 1-64 lowercase ASCII letters, digits, or dots after trimming; must resolve to an SF Symbol to render |
| Color string | Exactly seven ASCII bytes in `#RRGGBB` form |
| Transform string | At most 1,048,576 UTF-16 code units; content is otherwise preserved exactly |
| JavaScript exception message | Capped at 200 characters before display |
| Script load or validation | 0.5 seconds per load |
| Card-decoration hook | 0.1 seconds per hook, after loading succeeds |
| Transform hook | 0.25 seconds per call, after loading succeeds |
| Exception quarantine | 5 consecutive failure ticks; a failure-free evaluation resets the count |
| Timeout quarantine | Immediate, with the installed extension persistently disabled |
| Card result cache | Outcomes for at most 512 clip IDs; the in-memory cache clears on overflow |
| SF Symbol validation cache | Outcomes for at most 128 symbol names; the in-memory cache clears on overflow |

## Install and manage extensions

Open **Settings → Extensions** to manage extensions.

1. Paste a complete script into the editor and choose **Install Extension**.
   Installation evaluates the script once with the 0.5-second load limit to
   validate its registration.
2. Newly installed extensions are off by default. The installed row lists the
   hooks declared by the script. Use the switch beside an extension to enable
   it. A warning marks an extension that was automatically disabled; switching
   it on again clears the quarantine.
3. Use **Uninstall** to remove an extension. Its script text is deleted, so
   keep your own copy if you may need it again.

Pesty-Alvie checks the registration shape and execution limits, but it does not
review what pasted code does. Pasting a script is an explicit trust decision.

## Bundled example: Token Count

Token Count ships with Pesty-Alvie and is seeded off by default. It estimates
token count from text length and demonstrates a badge-only API 1 extension:

```javascript
pesty.register({
  id: "com.alvst.pesty-alvie.token-count",
  name: "Token Count",
  version: "1.0",
  api: 1,
  badge: function (clip) {
    var PROFILES = {
      "default": 4.0,
      "cjk-heavy": 1.5
    };
    var textTypes = ["text", "richText", "link", "file", "color"];
    if (textTypes.indexOf(clip.type) === -1 || clip.text.length === 0) {
      return null;
    }
    var count = Math.max(1, Math.ceil(clip.text.length / PROFILES["default"]));
    return "≈" + count + " tok";
  }
});
```

JSON Detector, shown in **Derived Categories**, is the second bundled example.
Both bundled extensions are seeded off by default in a fresh catalog.

## Versioning and distribution

The multi-hook contract remains API 1 because the expansion is additive.
Existing badge-only scripts still use the same registration fields, clip shape,
type strings, return rules, and limits; all new manifest fields and hooks are
optional. A breaking contract change still requires a new `api` value,
beginning with API 2.

Extensions are Mac-only for now. Direct and Mac App Store builds currently use
the same API. If App Review ever objects to pasted scripts, the Mac App Store
fallback plan is to allow bundled extensions only.
