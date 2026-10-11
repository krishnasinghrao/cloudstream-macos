# ADR-0021: library pages for titles and single episodes

**Status:** Accepted. 2026-10-08.
**[To-dos](../archive/plans/To-dos/to-dos.md):** feature ideas 1 (custom library pages), 2 (individual episodes on
a page) and 5 (Favorites, and now pages, on the Home row).

## Context

The Library only had fixed lists: the five watch statuses and Favorites. A
user who loves one episode of a show had nowhere to keep it, and could not
group titles their own way ("Rewatch", "Watch with friends"). The Home row
offered the watch statuses only, not Favorites.

## Decision

Two SwiftData models in each profile's store (additive, lightweight
migration; ADR-0006):

- `LibraryPage`: ID, name, creation date, sidebar position. Names are one
  line, at most 60 characters and unique ignoring case, so the sidebar and
  menus are unambiguous.
- `LibraryPageEntry`: one title (`episodeData` nil) or one episode on one
  page. The key is the page, the title's `StoredMediaItem.id` and a hash of
  the episode data (as `EpisodeProgress` keys are), so an item is on a page
  at most once.

**Entries keep their own display copy** (title, artwork, provider, URL,
episode name, season, number, edition). A page therefore never puts a title
into a watch list, survives the title leaving the library or its history
being cleared, and needs no title row to exist. The title's ID still links
the entry to its history, so episode cards show progress and watched marks,
and the provider-identity migration re-keys entries with everything else.

**Episodes play from the page.** Clicking an episode card loads the show's
episode list and plays that episode, resuming it when it was left part-way.
Episode data that a provider has changed is found again by season, number
and edition (`LibraryStore.resumeEpisode`), and fails with a clear message
when that is ambiguous.

**Downloaded files stay out of pages.** They are tied to this Mac and to
a file path; the menus hide Add to Page for them and the store refuses them.

### Interface

- Sidebar: a **Pages** section under Library with a + in its header, aligned
  with the rows' count badges; counts are standard sidebar badges; drag to
  reorder; right-click to rename or delete. Also File ▸ New Library Page…
  (⌥⌘N; ⌘N is New Window and ⇧⌘N is Next Episode).
- **Add to Page** submenu, with a checkmark on the pages already holding the
  item and New Page…, on title pages (toolbar), episode rows, library cards,
  search and Discover results, and page cards.
- A page shows **Titles** as 2:3 posters and **Episodes** as 16:9 cards, the
  same shape as the episode list on a show's page. It sorts by date added or
  name and is filtered by the window's search field.
- The Home row picker offers the watch statuses, Favorites and every page.
  A deleted page falls back to Plan to Watch.

### Backups

`BackupDocument.pages` is optional and additive, so the format version stays
2 and older apps ignore it. Merge restores add a page's missing entries to
the local page with the same ID, or else the same name; other pages are
appended. Replace restores replace the local pages only when the backup has
a `pages` list: a backup made before pages leaves them alone.

## Consequences

- An entry's copy of the title's name and artwork does not follow later
  changes on the provider; opening the title shows the current page.
- Pages are per profile, like the rest of the library. The Home row choice
  is a Mac-wide preference, so a page of another profile shows the default
  row instead.
