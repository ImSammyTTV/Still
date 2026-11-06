import AppKit
import StillCore

// `Still --mcp` is Claude's connection to Still (see StillConnector): no window, just MCP on stdin/stdout.
if CommandLine.arguments.contains("--mcp") {
    StillConnector.runBridge(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1")
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppController()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
