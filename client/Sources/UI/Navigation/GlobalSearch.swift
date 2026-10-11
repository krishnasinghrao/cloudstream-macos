import SwiftUI

/// The window's single toolbar search field, present on every screen.
///
/// On a Library collection it filters that collection; everywhere else it
/// searches providers and moves to the Search screen as soon as the user types.
/// Applied to every root screen (not pushed title pages) so the toolbar is
/// populated on each of them and the title bar height is stable (SwiftUI removes the window's
/// toolbar entirely when the visible screen contributes no items).
struct GlobalSearchModifier: ViewModifier {
    @Environment(WindowSession.self) private var windowSession

    @State private var suggestions: [SearchSuggestionService.SearchSuggestion] = []
    @State private var suggestionTask: Task<Void, Never>?
    /// The query the user last committed (Return or a picked suggestion).
    /// Suggestions stay dismissed until the text differs from it.
    @State private var committedQuery: String?
    @FocusState private var isSearchFocused: Bool

    private var filtersLibrary: Bool { windowSession.selection.filtersLibrary }

    /// "Filter Watching…", "Filter Favourite Episodes…".
    private var filterPrompt: String {
        switch windowSession.selection {
        case .page(let id):
            let name = LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.page(id: id)?.name })
            return name.map { "Filter \($0)…" } ?? "Filter page…"
        default:
            return windowSession.selection.libraryCollection.map { "Filter \($0.title)…" } ?? "Filter…"
        }
    }

    private var showSuggestions: Bool {
        !filtersLibrary && !suggestions.isEmpty
    }

    func body(content: Content) -> some View {
        @Bindable var windowSession = windowSession

        content
            .searchable(
                text: filtersLibrary ? $windowSession.libraryFilter : $windowSession.searchQuery,
                prompt: filtersLibrary ? filterPrompt : "Search movies, series, anime…",
            )
            .searchFocused($isSearchFocused)
            // AppKit keeps the field first responder when clicking
            // non-focusable content; a click anywhere in the window's content
            // ends editing. Simultaneous, so the click still reaches its target.
            // The field itself lives in the NSToolbar, outside this hierarchy.
            .simultaneousGesture(
                TapGesture().onEnded { isSearchFocused = false },
                including: isSearchFocused ? .all : .subviews,
            )
            // Sidebar clicks are outside this hierarchy; end editing on navigation.
            .onChange(of: windowSession.selection) { isSearchFocused = false }
            .searchSuggestions {
                if showSuggestions {
                    ForEach(suggestions) { suggestion in
                        Button { pick(suggestion) } label: {
                            SuggestionRow(suggestion: suggestion)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onSubmit(of: .search, submit)
            .onChange(of: windowSession.searchQuery) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    suggestionTask?.cancel()
                    suggestions = []
                    committedQuery = nil
                    windowSession.clearSearch()
                } else {
                    showSearchScreen()
                    windowSession.performSearch(immediate: false)
                    if trimmed != committedQuery {
                        committedQuery = nil
                        fetchSuggestions(for: trimmed)
                    }
                }
            }
            .onDisappear { suggestionTask?.cancel() }
    }

    private func submit() {
        guard !filtersLibrary else { return }
        dismissSuggestions(committing: windowSession.searchQuery)
        showSearchScreen()
        windowSession.commitSearch()
    }

    private func pick(_ suggestion: SearchSuggestionService.SearchSuggestion) {
        dismissSuggestions(committing: suggestion.title)
        windowSession.searchQuery = suggestion.title
        windowSession.commitSearch()
    }

    private func showSearchScreen() {
        if windowSession.selection != .search || !windowSession.detailPath.isEmpty {
            windowSession.navigateTo(.search)
        }
    }

    /// Hides the suggestions and drops any fetch still in flight, so a late
    /// response cannot reopen the list over the committed search's results.
    private func dismissSuggestions(committing query: String) {
        suggestionTask?.cancel()
        suggestions = []
        committedQuery = query.trimmingCharacters(in: .whitespaces)
    }

    /// Cancels the previous fetch so a slow older response can never
    /// overwrite a newer query's suggestions.
    private func fetchSuggestions(for query: String) {
        suggestionTask?.cancel()
        suggestionTask = Task {
            let fetched = await SearchSuggestionService.shared.fetchSuggestions(query: query)
            if !Task.isCancelled {
                suggestions = fetched
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: SearchSuggestionService.SearchSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            Text(suggestion.title)
            if let year = suggestion.year {
                Text("(\(year))")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let type = suggestion.mediaType {
                Text(type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

extension View {
    func globalSearch() -> some View {
        modifier(GlobalSearchModifier())
    }
}
