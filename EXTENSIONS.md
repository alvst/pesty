# Pesty-Alvie extensions

Pesty-Alvie extensions are JavaScript snippets that compute short badges for
clip cards. API 1 has one hook: a synchronous `badge` function. Extensions
cannot change clips, paste content, add settings, or run commands.

Extensions are currently available only in the Mac app.

## Trust and execution model

The extension host exposes `pesty.register` to a JavaScriptCore context. It
does not expose network or file APIs. Browser and Node.js APIs such as `fetch`,
`XMLHttpRequest`, `require`, and `process` are not available.

The only clip content passed to an extension is the text of the single clip
being badged. The input also includes that clip's non-content type string. It
does not include clipboard history, other clips, source-app details, clip IDs,
timestamps, image data, or rich-text data. Clips marked concealed or transient
are rejected during capture, so they never reach an extension.

Each evaluation uses a fresh JavaScriptCore virtual machine. An extension does
not share a context or virtual machine with another extension, and contexts
are not reused after a failure. Badge evaluations run off the main thread.

This is a deliberately narrow host surface, not a hardened sandbox for
untrusted code. Pasted scripts still execute inside the Pesty-Alvie process.
Extensions are off by default; install and enable only code that you have read
and trust.

### Timeouts and quarantine

Loading a script has a 0.5-second budget. Calling its badge function has a
separate 0.1-second budget. A timeout immediately quarantines an installed
extension from further evaluation for the current app process. Five
consecutive script exceptions also quarantine it; a successful call resets
the exception count.

JavaScriptCore's public API cannot terminate a script that is already running.
On timeout, Pesty-Alvie stops waiting, abandons the worker thread, and disables
the extension. The script may continue consuming that thread and CPU until it
returns or Pesty-Alvie exits. This is a known limitation of API 1.

## API 1 contract

An extension must call `pesty.register` exactly once while its source is
loaded. The call takes one object:

```javascript
pesty.register({
  id: "com.example.word-count",
  name: "Word Count",
  version: "1.0",
  api: 1,
  badge: function (clip) {
    if (clip.type !== "text" || clip.text.length === 0) {
      return null;
    }
    return clip.text.trim().split(/\s+/).length + " words";
  }
});
```

The registration fields are:

- `id`: the extension's stable identifier.
- `name`: the display name shown in Settings.
- `version`: the extension author's version string.
- `api`: the Pesty-Alvie extension API version. API 1 requires the integer
  `1`.
- `badge`: a synchronous function receiving one clip object.

The clip object has this shape:

```javascript
{
  type: "text", // text, richText, link, image, file, or color
  text: "The bounded text for this clip"
}
```

`badge` must return synchronously. A string becomes the badge after
sanitization. `null`, `undefined`, and every other non-string result mean that
no badge is shown. Empty strings also produce no badge. Returning a Promise is
not supported and produces no badge.

### Limits

| Surface | API 1 limit |
| --- | --- |
| `pesty.register` | Exactly one call per script load |
| `id` | String; 3-64 ASCII letters, digits, dots, or hyphens; must contain at least one letter |
| `name` | Non-empty string after trimming whitespace; at most 40 characters |
| `version` | Non-empty string after trimming whitespace; at most 16 characters |
| `api` | Integer equal to `1` |
| `badge` | Required function; called synchronously with one clip object |
| `clip.type` | One of `text`, `richText`, `link`, `image`, `file`, or `color` |
| `clip.text` | At most 65,536 UTF-16 code units |
| Badge string | Trimmed, stripped of control/newline characters, then capped at 24 characters |
| JavaScript exception message | Capped at 200 characters before display |
| Script load or validation | 0.5 seconds per load |
| Badge function | 0.1 seconds per call, after loading succeeds |
| Exception quarantine | 5 consecutive failures; a success resets the count |
| Timeout quarantine | Immediate for an installed extension |
| Result cache | Outcomes for at most 512 clip IDs; the in-memory cache clears on overflow |

## Install and manage extensions

Open **Settings → Extensions** to manage extensions.

1. Paste a complete script into the editor and choose **Install Extension**.
   Installation evaluates the script once with the 0.5-second load limit to
   validate its registration.
2. Newly installed extensions are off by default. Use the switch beside an
   extension to enable it.
3. Use **Uninstall** to remove an extension. Its script text is deleted, so
   keep your own copy if you may need it again.

Pesty-Alvie checks the registration shape and execution limits, but it does
not review what pasted code does. Pasting a script is an explicit trust
decision.

## Bundled example: Token Count

Token Count ships with Pesty-Alvie and is seeded off by default. It estimates
token count from text length and demonstrates the complete API 1 contract:

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

## Versioning and distribution

API 1 is frozen. Existing API 1 scripts will keep the registration fields,
clip shape, type strings, and behavior documented above. A breaking contract
change requires a new `api` value, beginning with API 2.

Extensions are Mac-only for now. Direct and Mac App Store builds currently use
the same API. If App Review ever objects to pasted scripts, the Mac App Store
fallback plan is to allow bundled extensions only.
