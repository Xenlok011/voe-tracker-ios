import SwiftUI
import UIKit

@main
struct VoeTrackerApp: App {
    @State private var incomingJSON: String? = nil

    var body: some Scene {
        WindowGroup {
            ContentView(externalJSON: \$incomingJSON)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "voetracker" else { return }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let dataParam = components.queryItems?.first(where: { \$0.name == "data" })?.value {
                let normalized = dataParam
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
                let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
                if let decoded = Data(base64Encoded: padded),
                   let jsonStr = String(data: decoded, encoding: .utf8),
                   !jsonStr.isEmpty {
                    incomingJSON = jsonStr
                    return
                }
            }

            if components.queryItems?.contains(where: { \$0.name == "clipboard" && \$0.value == "1" }) == true,
               let pasteStr = UIPasteboard.general.string,
               !pasteStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                incomingJSON = pasteStr
            }
        }
    }
}
