enum BundledExtensions {
    static let tokenCount = #"""
    pesty.register({
      id: "com.alvst.pesty-alvie.token-count",
      name: "Token Count",
      version: "1.0",
      api: 1,
      config: [
        {
          key: "profile",
          type: "choice",
          label: "Token profile",
          default: "default",
          options: ["default", "cjk-heavy"]
        }
      ],
      badge: function (clip) {
        var PROFILES = {
          "default": 4.0,
          "cjk-heavy": 1.5
        };
        var textTypes = ["text", "richText", "link", "file", "color"];
        if (textTypes.indexOf(clip.type) === -1 || clip.text.length === 0) {
          return null;
        }
        var profile = config.profile || "default";
        var count = Math.max(1, Math.ceil(clip.text.length / PROFILES[profile]));
        return "≈" + count + " tok";
      }
    });
    """#

    static let jsonDetector = #"""
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
    """#
}
