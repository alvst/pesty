enum BundledExtensions {
    static let tokenCount = #"""
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
    """#
}
