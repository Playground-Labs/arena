import Sparkle
import SwiftUI

struct CheckForUpdatesView: View {
    let updater: SPUUpdater
    @State private var canCheck = false
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!canCheck)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
