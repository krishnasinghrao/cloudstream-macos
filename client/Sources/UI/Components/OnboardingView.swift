import SwiftUI

/// First use always has a recoverable path, including an empty/offline engine.
/// Choosing extensions opens the normal catalog flow rather than bulk-installing
/// executable code or waiting on a provider picker that cannot populate itself.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var windowSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.tv.fill")
                .font(.largeTitle).imageScale(.large).foregroundStyle(Color.accentColor)
            Text("Welcome to CloudStream").font(.largeTitle.weight(.bold))
            Text("Choose repositories you trust, browse their catalogs, and install the extensions you want to use.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("You can manage repositories and extensions at any time from Extensions.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !appState.isEngineReady {
                Label("The extension engine is starting. You can continue while it connects.", systemImage: "network")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Choose Extensions") { finish(destination: .extensions) }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            Button("Set Up Later") { finish(destination: .home) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(32).frame(maxWidth: .infinity)
    }

    private func finish(destination: AppDestination) {
        appState.preferences.onboardingComplete = true
        windowSession.navigateTo(destination)
        dismiss()
    }
}
