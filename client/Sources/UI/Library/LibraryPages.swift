import SwiftUI

// MARK: - Page editing (ADR-0021)

/// What the page name sheet does when confirmed.
struct PageEditorRequest: Identifiable {
    enum Mode {
        /// A new page; `adding` is put on it straight away (Add to Page ▸ New Page…).
        case create(adding: PageAddition?)
        case rename(pageID: String, currentName: String)
    }

    let id = UUID()
    let mode: Mode
}

/// A title (`episode` nil) or an episode waiting to be put on a page.
struct PageAddition {
    let details: DetailsDto
    let episode: EpisodeDto?
}

/// Names a new page or renames one. Validation errors stay in the sheet.
struct PageEditorSheet: View {
    let request: PageEditorRequest
    @Environment(WindowSession.self) private var windowSession
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    private var isRename: Bool {
        if case .rename = request.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isRename ? "Rename Page" : "New Page").font(.headline)
            TextField("Name", text: $name, prompt: Text("Favourite Episodes"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
                .onChange(of: name) { failure = nil }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if !isRename {
                Text("Pages hold the titles and single episodes you choose. Right-click any title or episode and choose Add to Page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Create", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(LibraryPage.normalizedName(name) == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if case .rename(_, let currentName) = request.mode { name = currentName }
            nameFocused = true
        }
        .onChange(of: ProfileStore.shared.activeID) { dismiss() }
        .onChange(of: AppLock.shared.isLocked) { _, locked in if locked { dismiss() } }
    }

    private func save() {
        guard LibraryPage.normalizedName(name) != nil else { return }
        let store = LibraryStore.shared
        do {
            switch request.mode {
            case .rename(let pageID, _):
                try store.renamePage(id: pageID, to: name)
            case .create(let addition):
                let pageID = try store.createPage(named: name)
                if let addition {
                    try store.setPageMembership(pageID: pageID, details: addition.details, episode: addition.episode, isMember: true)
                    appState.presentNotice("Added to “\(LibraryPage.normalizedName(name) ?? name)”")
                } else {
                    windowSession.navigateTo(.page(pageID))
                }
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

extension View {
    /// The page sheet and delete confirmation for one window.
    func pageEditing(_ windowSession: WindowSession) -> some View {
        modifier(PageEditing(windowSession: windowSession))
    }
}

private struct PageEditing: ViewModifier {
    @Bindable var windowSession: WindowSession

    func body(content: Content) -> some View {
        content
            .sheet(item: $windowSession.pageEditor) { request in
                // Applied outside the window's own environment modifier.
                PageEditorSheet(request: request)
                    .environment(windowSession)
            }
            .confirmationDialog(
                windowSession.pageToDelete.map { "Delete “\($0.name)”?" } ?? "",
                isPresented: Binding(get: { windowSession.pageToDelete != nil },
                                     set: { if !$0 { windowSession.pageToDelete = nil } }),
                presenting: windowSession.pageToDelete,
            ) { page in
                Button("Delete Page", role: .destructive) {
                    guard LibraryStore.shared.perform({ try LibraryStore.shared.deletePage(id: page.id) }) else { return }
                    if windowSession.selection == .page(page.id) { windowSession.navigateTo(.home) }
                }
            } message: { _ in
                Text("The titles and episodes on it stay in your library, with their history.")
            }
    }
}

// MARK: - Add to Page

/// "Add to Page" submenu for a title (`episode` nil) or an episode: every
/// page with a checkmark where it already is, and New Page….
struct AddToPageMenu: View {
    let details: DetailsDto
    var episode: EpisodeDto? = nil
    @Environment(WindowSession.self) private var windowSession

    var body: some View {
        // Downloaded files are machine-specific and stay out of pages.
        if details.type != "Download", details.localDownloadID == nil {
            Menu {
                let store = LibraryStore.shared
                let pages = store.readForDisplay(or: [], { try store.pages() })
                let member = store.readForDisplay(or: [], { try store.pageIDs(containing: details, episode: episode) })
                ForEach(pages) { page in
                    Toggle(page.name, isOn: Binding(
                        get: { member.contains(page.id) },
                        set: { isMember in
                            store.perform {
                                try store.setPageMembership(pageID: page.id, details: details, episode: episode, isMember: isMember)
                            }
                        },
                    ))
                }
                if !pages.isEmpty { Divider() }
                Button("New Page…") {
                    windowSession.pageEditor = PageEditorRequest(mode: .create(adding: PageAddition(details: details, episode: episode)))
                }
            } label: {
                Label("Add to Page", systemImage: "rectangle.stack.badge.plus")
            }
        }
    }
}
