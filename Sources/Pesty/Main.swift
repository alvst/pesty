import AppKit

@main
struct PestyMain {
    static func main() {
        let intent = AppLaunchIntent.parse(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment)
        AppRuntime.install(.make(for: intent))

        let app = NSApplication.shared
        let delegate = AppController.shared
        app.delegate = delegate
        app.run()
    }
}
