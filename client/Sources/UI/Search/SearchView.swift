import SwiftUI

/// Search results, grouped per provider shelf. The query is edited in the
/// window's global toolbar search field (GlobalSearchModifier), which also
/// provides live TMDB suggestions.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var windowSession
    /// Type filter chips (nil = everything). Cleared with each new query.
    @State private var category: MediaCategory?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                if let searchError = windowSession.searchError, !windowSession.searchResults.isEmpty {
                    // A stream that failed part-way keeps what it found.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label("Search stopped early: \(searchError)", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { windowSession.commitSearch() }
                    }
                    .padding(.horizontal, 24)
                    resultsHeader
                    categoryChips
                    providerShelves
                } else if let searchError = windowSession.searchError {
                    errorSection(searchError)
                } else if windowSession.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !appState.preferences.recentlySearched.isEmpty {
                        recentlySearchedSection
                    } else {
                        ContentUnavailableView.search
                            .padding(.top, 40)
                    }
                } else if windowSession.isSearching && windowSession.searchResults.isEmpty {
                    LoadingView("Searching providers…")
                        .frame(height: 240)
                } else if windowSession.searchResults.isEmpty && !windowSession.searchProviderErrors.isEmpty {
                    // Failures must never look like "nothing found".
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "No results for “\(windowSession.searchQuery)”",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Some providers couldn't search."),
                        )
                        providerFailureList
                        Button("Retry") { windowSession.commitSearch() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 40)
                } else if windowSession.searchResults.isEmpty {
                    ContentUnavailableView(
                        "No results for “\(windowSession.searchQuery)”",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different title, or check your installed extensions."),
                    )
                    .padding(.top, 40)
                } else {
                    resultsHeader
                    categoryChips
                    providerShelves
                }
            }
            .padding(.vertical, 24)
            // The empty states are narrower than the column. Without this the
            // scroll view shrinks to their width and its toolbar scroll-edge
            // backdrop shows as a rectangle in the middle of the title bar.
            .frame(maxWidth: .infinity)
        }
        .onChange(of: windowSession.searchQuery) { _, _ in category = nil }
    }

    /// Only categories present in the results get a chip.
    @ViewBuilder
    private var categoryChips: some View {
        let present = Set(windowSession.searchResults.map { MediaCategory.of($0.type) })
        if present.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip(title: "All", symbol: "square.stack", selected: category == nil) { category = nil }
                    ForEach(MediaCategory.allCases.filter(present.contains)) { candidate in
                        let count = windowSession.searchResults.filter { MediaCategory.of($0.type) == candidate }.count
                        chip(title: "\(candidate.rawValue) \(count)", symbol: candidate.symbolName, selected: category == candidate) {
                            category = category == candidate ? nil : candidate
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func chip(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.cardSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Sections

    private func errorSection(_ message: String) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Search Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message),
            )
            Button("Retry") { windowSession.commitSearch() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }

    /// Each failed provider with the engine's reason, so a failure is never silent.
    private var providerFailureList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(windowSession.searchProviderErrors.sorted(by: { $0.key < $1.key }), id: \.key) { provider, reason in
                Text("\(provider): \(reason)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var recentlySearchedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recently Searched")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Clear") {
                    appState.preferences.clearSearchHistory()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 28)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(appState.preferences.recentlySearched) { result in
                        RecentlySearchedCard(result: result) {
                            appState.preferences.rememberSearch(result)
                            windowSession.openDetails(result)
                        }
                        .contextMenu {
                            Button("Remove from Recently Searched") {
                                appState.preferences.forgetSearch(result)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var resultsHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(windowSession.searchResults.count) Results")
                    .font(.title3.weight(.semibold))

                if windowSession.isSearching {
                    ProgressView().controlSize(.small)
                    Text("searching providers…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)

            if !windowSession.searchProviderErrors.isEmpty && !windowSession.isSearching {
                DisclosureGroup {
                    providerFailureList
                } label: {
                    HStack {
                        Text("\(windowSession.searchProviderErrors.count) provider\(windowSession.searchProviderErrors.count == 1 ? "" : "s") failed")
                        Button("Retry") { windowSession.commitSearch() }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            }
        }
    }

    private var providerShelves: some View {
        let grouped = groupedResultsByProvider()

        return VStack(alignment: .leading, spacing: 28) {
            ForEach(grouped, id: \.provider) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(group.provider)
                            .font(.title3.weight(.semibold))
                        Text("(\(group.results.count))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 28)

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(group.results) { result in
                                Button {
                                    appState.preferences.rememberSearch(result)
                                    windowSession.openDetails(result)
                                } label: {
                                    PosterCard(
                                        title: result.name,
                                        subtitle: result.year.map(String.init) ?? MediaTypeDisplay.name(for: result.type),
                                        posterURL: result.posterUrl,
                                        posterHeaders: result.posterHeaders,
                                    )
                                }
                                .buttonStyle(.plain)
                                .frame(width: 168)
                                .contextMenu { DiscoverItemMenu(item: result) }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private func groupedResultsByProvider() -> [(provider: String, results: [SearchResultDto])] {
        var groups: [String: [SearchResultDto]] = [:]
        for result in windowSession.searchResults where category == nil || MediaCategory.of(result.type) == category {
            groups[result.provider, default: []].append(result)
        }
        return groups.keys.sorted().map { provider in
            (provider: provider, results: groups[provider] ?? [])
        }
    }
}
