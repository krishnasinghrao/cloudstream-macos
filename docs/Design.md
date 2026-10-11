# Design Specification: CloudStream macOS (Apple TV macOS Native Integration)

## 1. Design Vision & Philosophy

**CloudStream macOS** is an end-to-end integration of **CloudStream’s aggregation engine** into the **Apple TV macOS native application design system**. 

Every window, view, component, and interaction strictly adheres to Apple’s **macOS Human Interface Guidelines (HIG)** and mirrors the cinematic ergonomics of the macOS Apple TV app (macOS Sonoma / Sequoia / Tahoe):

* **The Obsidian Dark Canvas (`#111214`):** An ambient, deep dark background where interface chrome dissolves into the background, prioritizing high-resolution widescreen backdrops and poster artwork.
* **Frosted Glass Vibrancy (`.ultraThinMaterial`):** Apple's native `NSVisualEffectView` materials that sample desktop wallpaper and window contents behind the sidebar and player controls.
* **Apple TV Content Hierarchy:** 
  - **16:9 Landscape Cards** for *Continue Watching* and *Episodes* with integrated progress scrubbers and time remaining.
  - **2:3 Portrait Cards** for provider shelves and library browsing with smooth continuous squircle corners (`style: .continuous`).
* **Signature Apple TV Action Pills:** High-contrast solid white primary play buttons (`#FFFFFF` with `#000000` text) paired with frosted translucent secondary capsules.
* **CloudStream Core Fidelity:** 100% functional retention of CloudStream's scraper provider selection, `WatchType` status tracking, mirror/server resolution, and subtitle/audio stream customization.

---

## 2. Window Anatomy & Structural Layout

```
+---------------------------------------------------------------------------------------------------------+
| [●][●][●]                                                                     [Provider: SuperStream ▾] |
+-------------------+-------------------------------------------------------------------------------------+
| SIDEBAR (240pt)   | MAIN WORKSPACE CANVAS                                                               |
|                   |                                                                                     |
| 🔍 Search         |  Continue Watching >                                                                |
| 􀎞 Home (Active)   |  +--------------------+  +--------------------+  +--------------------+             |
|                   |  | [16:9 Backdrop] 􀎞  |  | [16:9 Backdrop] 􀎞  |  | [16:9 Backdrop] 􀎞  |             |
| LIBRARY           |  | S1, E2 • Ted Lasso |  | S2, E1 • Silo      |  | 2h 26m • F1 Movie  |             |
| 􀐫 Recently Added  |  | ▶ ───●──── 18m left|  | ▶ ───────● 12m left|  | ▶ ──────── 1h 45m  |             |
| 􀑈 Movies          |  +--------------------+  +--------------------+  +--------------------+             |
| 􀌖 TV Shows        |                                                                                     |
| 􀈂 Downloaded      |  Popular on SuperStream >                                                           |
|                   |  +--------+  +--------+  +--------+  +--------+  +--------+  +--------+             |
| ----------------- |  | [2:3]  |  | [2:3]  |  | [2:3]  |  | [2:3]  |  | [2:3]  |  | [2:3]  |             |
| 􀣋 Settings        |  | Title  |  | Title  |  | Title  |  | Title  |  | Title  |  | Title  |             |
| 􀀁 Engine: Ready   |  | Comedy |  | Sci-Fi |  | Drama  |  | Action |  | Anime  |  | Horror |             |
+-------------------+-------------------------------------------------------------------------------------+
```

### 2.1 Window Configuration
* **Dimensions:** Default `1280pt × 800pt`, Minimum `1024pt × 640pt`, Fullscreen support (`F` or `Cmd+Ctrl+F`).
* **Titlebar Configuration:**
  - Style: `.windowToolbarStyle(.unified)`
  - Titlebar Background: 100% Transparent (`.titlebarAppearsTransparent(true)`).
  - Leading Chrome: Standard macOS traffic lights (Close, Minimize, Zoom) inset `16pt` horizontally and `16pt` vertically.
  - Trailing Toolbar Accessory: Minimalist glass Provider Switcher dropdown (`[ Provider: SuperStream ▾ ]`).
* **Window Background:** Deep obsidian neutral `#111214`.

---

## 3. The Apple TV Sidebar Specification

Built using native SwiftUI `NavigationSplitView` with an `NSVisualEffectView` backing (`material: .sidebar`, `blendingMode: .behindWindow`):

### 3.1 Sidebar Navigation Sections
1. **Top Navigation Group:**
   - **`Search` (`magnifyingglass`):** Instant search destination with keyboard shortcut `Cmd+F` / `Cmd+K`.
   - **`Home` (`house.fill`):** The primary media hub featuring Continue Watching and active provider feeds.
2. **Library Group Header (`LIBRARY`):** `11pt` Bold uppercase, tracking `+0.4pt`, tint `tvTextTertiary`.
3. **Library Navigation Items (Apple TV Standard):**
   - **`Recently Added` (`clock.arrow.circlepath`):** Chronological feed of newly bookmarked and tracked titles.
   - **`Movies` (`film.fill`):** Filtered library view for films.
   - **`TV Shows` (`tv.fill`):** Filtered library view for episodic series.
   - **`Downloaded` (`arrow.down.circle.fill`):** Offline media library and active download queue.
4. **Sidebar Footer:**
   - **`Settings` (`gearshape.fill`):** App preferences, extensions, accounts, and storage.
   - **`Engine Status Indicator`:** Mini glowing dot (`8pt`) `#34C759` (Connected) with label `"Daemon: Ready"`.

### 3.2 Row Selection Styling
* **Active Row:** Solid Apple Blue pill (`#0A84FF`), cornerRadius `8pt`, white icon and semibold label.
* **Inactive Row:** Transparent fill, `tvTextSecondary` icon and label.
* **Hover State:** Soft translucent tint (`Color.white.opacity(0.06)`), spring transition.

---

## 4. Screen-by-Screen UI Specifications

### 4.1 Home Screen (`Home`)

Directly mirroring the Apple TV Home experience (Screenshot 2):

#### Section 1: "Continue Watching >" (16:9 Landscape Shelf)
* **Header:** `"Continue Watching"` in `SF Pro Display 19pt Bold` with trailing chevron `>` (clicking navigates to full watch history).
* **Card Dimensions:** `280pt` width × `158pt` height (16:9 widescreen aspect ratio).
* **Corner Geometry:** `12pt` continuous squircle (`.rect(cornerRadius: 12, style: .continuous)`).
* **Visual Layers:**
  1. **High-Res Backdrop:** Scraped episode/movie backdrop artwork (`.aspectRatio(16/9, contentMode: .fill)`).
  2. **Top-Right Provider Tag:** Translucent badge displaying source provider logo or name (e.g., `SuperStream`).
  3. **Bottom Shading Vignette:** Linear dark gradient (`.clear` to `Color.black.opacity(0.85)`).
  4. **Progress Bar:**
     - Capsule track height: `3pt`.
     - Inactive background: `Color.white.opacity(0.3)`.
     - Active progress fill: Pure white `#FFFFFF`.
  5. **Metadata Row:**
     - Play Glyph: `play.fill` (`10pt`).
     - Time Remaining / Episode Code: `"2h 26m"` or `"S1, E2 • 26m"` in `11pt Medium` white.
     - Ellipsis Button: `ellipsis` triggering context menu:
       - *Resume Playback*
       - *Play from Beginning*
       - *Mark as Watched*
       - *Download Episode*
       - *Remove from Continue Watching*
* **Hover Interaction:** Scales up `1.04x` with `.spring(response: 0.28, dampingFraction: 0.75)` and soft drop shadow.

#### Section 2: Dynamic Provider Shelves (2:3 Portrait Shelves)
* **Data Source:** Dynamically generated from the selected provider's `MainAPI.getMainPage()` (e.g. *Popular Movies >*, *Trending Series >*, *Latest Releases >*).
* **Card Dimensions:** `170pt` width × `255pt` height (2:3 aspect ratio).
* **Content:** Edge-to-edge poster artwork, show title in `13pt Bold`, genre/year in `11pt tvTextSecondary`.

---

### 4.2 Search & Browse Screen (`Search`)

Directly mirroring the Apple TV Search experience (Screenshot 1):

```
+---------------------------------------------------------------------------------------------------------+
|                                    [ 🔍 Shows, Movies, and More          ]                              |
|                                                                                                         |
| Recently Searched                                                                                 Clear |
| +-------------------------+  +-------------------------+  +-------------------------+                   |
| |[16:9]  Pluribus         |  |[16:9]  F1 The Movie     |  |[16:9]  E.T.             |                   |
| |        TV Show          |  |        Movie            |  |        Movie            |                   |
| +-------------------------+  +-------------------------+  +-------------------------+                   |
|                                                                                                         |
| Browse Categories                                                                                       |
| +--------+  +--------+  +--------+  +--------+  +--------+  +--------+                                  |
| | [2:3]  |  | [2:3]  |  | [2:3]  |  | [2:3]  |  | [2:3]  |  | [2:3]  |                                  |
| | Action |  | Anime  |  | Drama  |  | Sci-Fi |  | Comedy |  | Asian  |                                  |
| | [Grad] |  | [Grad] |  | [Grad] |  | [Grad] |  | [Grad] |  | Drama  |                                  |
| +--------+  +--------+  +--------+  +--------+  +--------+  +--------+                                  |
+---------------------------------------------------------------------------------------------------------+
```

1. **Top Search Capsule:**
   - Centered in the Search view header: `380pt × 34pt`, `cornerRadius: 17pt`.
   - Fill: `Color.white.opacity(0.08)`, stroke: `1pt` `Color.white.opacity(0.12)`.
   - Placeholder: `"Shows, Movies, and More"`.
2. **"Recently Searched" Section (Screenshot 1):**
   - Header with trailing blue `"Clear"` button.
   - Horizontal capsule cards (`220pt × 56pt`):
     - Left: 16:9 preview thumbnail (`cornerRadius: 6pt`).
     - Right: Title (`13pt Bold`) and media type (`11pt Regular tvTextSecondary`).
3. **"Browse Categories" Grid (Screenshot 1):**
   - 2:3 vertical cards with rich, dual-tone blurred ambient gradients.
   - White category title positioned at bottom-left in `16pt Bold` (e.g. *Action*, *Anime*, *Bollywood*, *Sci-Fi*, *Documentaries*).
4. **Live Search Results Grid:**
   - Streams in results progressively across active CloudStream providers.
   - 2:3 poster cards with provider origin pill in top corner.

---

### 4.3 Media Details View (The Apple TV Hero Layout)

When any title is selected, it presents a cinematic full-window view (replacing `ResultFragment`):

```
+---------------------------------------------------------------------------------------------------------+
| [← Back]                                                            [􀈂 Share] [􀉣 Open in Browser]      |
|                                                                                                         |
|  Ted Lasso                                                                                              |
|  2020 • TV-MA • 3 Seasons • 4K • HDR • 8.8/10 IMDb • Comedy, Drama • Provider: SuperStream              |
|                                                                                                         |
|  [ ▶ Play S1, E1 ]   [ 􀈑 In Library ▾ ]   [ 􀈂 Download Season ]   [ 􀍠 Server: Vidplay ▾ ]              |
|                                                                                                         |
|  American college football coach Ted Lasso heads to London to manage AFC Richmond, a struggling        |
|  English Premier League soccer team...                                                                  |
|                                                                                                         |
| ------------------------------------------------------------------------------------------------------- |
|  Episodes                             [ Season 1 ▾ ] [ Dub / Sub: Subbed ▾ ]  [ Sort: 1-N ▾ ]          |
|                                                                                                         |
|  +--------------------+  Episode 1: Pilot                                                [ ▶ Play ]     |
|  | [16:9 Thumbnail]   |  Ted Lasso, a small-time American football coach, is hired to   [ 􀈂 1080p ▾ ]  |
|  | 30m • Watched      |  coach a professional soccer team in England...                 [ 􀍠 Mirror ▾ ] |
|  +--------------------+                                                                                 |
+---------------------------------------------------------------------------------------------------------+
```

#### The Apple TV Action Bar:
1. **Primary Play Pill (Apple TV Signature):**
   - Solid pure white capsule: `Color.white`.
   - Text & Icon: Solid black `#000000` in `SF Pro Text 14pt Semibold`.
   - Label: `"▶ Play S1, E1"` or `"▶ Resume"`.
   - Hover: `scaleEffect(1.03)` with bright specular glow.
2. **Library Status Capsule (`WatchType` Dropdown):**
   - Frosted translucent capsule: `Color.white.opacity(0.12)`.
   - Text & Icon: Pure white `#FFFFFF`.
   - Label: Displays current status (`"􀈑 Watching ▾"`, `"􀈑 Plan to Watch ▾"`, etc.).
   - Click opens Apple-style menu with the 5 CloudStream `WatchType` states.
3. **Download Season Capsule:**
   - Frosted translucent capsule with `arrow.down.circle.fill`.
4. **Mirror / Source Selector:**
   - Lets user switch between video hosts (Vidplay, Streamtape, Filemoon) before playback.
5. **Episodes Shelf / List:**
   - Horizontal season picker tabs: `[ Season 1 ] [ Season 2 ] [ Season 3 ]`.
   - 16:9 widescreen episode cards with thumbnail, progress indicator, episode title, runtime, synopsis, and quick Play/Download actions.

---

### 4.4 Video Player Viewport (`libmpv` in Apple TV Player Skin)

Full-window video playback powered by `CAMetalLayer` with Apple TV’s signature floating glass HUD:

```
+---------------------------------------------------------------------------------------------------------+
| [← Back]  Ted Lasso — S1:E4 "The Anchor"                                                                |
|                                                                                                         |
|                                      [VIDEO PLAYBACK CANVAS]                                            |
|                                                                                                         |
|                                                                                                         |
|                     +-------------------------------------------------------------+                     |
|                     | [ 􀊉 10 ]     [  ▶ / ⏸  ]     [ 􀊈 10 ]                       |                     |
|                     | 08:42 ───────────────●──────────────────────────── -21:18   |                     |
|                     | [􀑈 Next Ep] [􀊂 Subtitles ▾] [􀊠 Audio ▾] [􀍠 1080p ▾] [􀑊 PiP]|                     |
|                     +-------------------------------------------------------------+                     |
+---------------------------------------------------------------------------------------------------------+
```

* **Floating Glass Capsule HUD:** Centered `32pt` above the bottom edge (`640pt × 68pt`, `.ultraThinMaterial`, `cornerRadius: 34pt`).
* **Transport Controls:**
  - `gobackward.10` (Rewind 10s)
  - Circular Play/Pause button (`play.fill` / `pause.fill`)
  - `goforward.10` (Fast forward 10s)
* **High-Precision Scrubber Bar:** Native Apple TV slider with elapsed time (`08:42`) and remaining time (`-21:18`).
* **CloudStream Popover Menus:**
  - **Subtitles (`captions.bubble.fill`):** Track selector (.srt, .vtt), subtitle delay offset (`-2.5s` to `+2.5s`), font size, color, background outline.
  - **Audio (`speaker.wave.2.fill`):** Track selector (stereo, 5.1 surround).
  - **Server / Quality (`slider.horizontal.3`):** Switch hosters or stream qualities (4K, 1080p, 720p).
  - **Next Episode (`forward.end.fill`):** Quick jump to next episode.
  - **Picture-in-Picture (`pip.fill`):** Native macOS PiP window.

---

### 4.5 Library Screen (`Library`)

Organizes the user's saved titles with CloudStream's `WatchType` filter tabs:

* **Top Filter Capsule Bar:**
  - `[ All (42) ] [ Watching (8) ] [ Plan to Watch (16) ] [ Completed (14) ] [ On Hold (3) ] [ Dropped (1) ]`
  - Pill-style segmented control in `.ultraThinMaterial`.
* **Grid Layout:** 2:3 portrait cards in a responsive macOS grid (4 to 6 columns).
* **Card Details:** Poster artwork, episode progress badge (e.g. `"S2 • E6 / 10"`), and subtle status pill.

---

### 4.6 Downloaded Screen (`Downloads`)

* **Segmented Control:** `[ Downloaded Titles (12) ]  [ Active Queue (2) ]`
* **Active Queue View:**
  - Table showing Thumbnail, Title, Speed (`"16.2 MB/s"`), Progress Bar (`64%`), ETA (`"1m 20s"`).
  - Actions: Pause, Resume, Cancel, Reveal in Finder (`folder.fill`).
* **Storage Footprint Bar:** Native storage gauge displaying Free Space vs. CloudStream Offline Media.

---

## 5. Color Tokens & Materials (Apple TV Design System)

```swift
extension Color {
    // Canvas & Dark Obsidian Surfaces
    static let tvCanvas = Color(red: 0.067, green: 0.071, blue: 0.078)      // #111214
    static let tvSurfaceDark = Color(red: 0.094, green: 0.102, blue: 0.110)  // #181A1C
    static let tvCardSurface = Color(red: 0.133, green: 0.141, blue: 0.153)  // #222427
    
    // Apple Blue & Primary Action
    static let tvAccentBlue = Color(red: 0.039, green: 0.518, blue: 1.000)   // #0A84FF
    static let tvActionWhite = Color.white                                   // #FFFFFF
    static let tvActionBlack = Color.black                                   // #000000
    
    // Text Hierarchy
    static let tvTextPrimary = Color.white                                   // #FFFFFF
    static let tvTextSecondary = Color(red: 0.627, green: 0.627, blue: 0.647) // #A0A0A5
    static let tvTextTertiary = Color(red: 0.447, green: 0.447, blue: 0.471)  // #727278
    
    // Glass & Specular Overlays
    static let tvGlassPill = Color.white.opacity(0.12)
    static let tvGlassBorder = Color.white.opacity(0.14)
    static let tvSpecularGlow = Color.white.opacity(0.16)
}
```

---

## 6. Keyboard Shortcuts Matrix

| Action | Primary Shortcut | Secondary Shortcut |
| :--- | :--- | :--- |
| **Play / Pause** | `Space` | `K` |
| **Seek -10s / +10s** | `Left Arrow` / `Right Arrow` | `J` / `L` |
| **Next Episode** | `Shift + N` | — |
| **Toggle Fullscreen** | `F` | `Cmd + Ctrl + F` |
| **Mute / Unmute** | `M` | `Cmd + Down Arrow` |
| **Subtitles Menu** | `S` | — |
| **Audio Track Menu** | `A` | — |
| **Focus Search** | `Cmd + F` | `Cmd + K` |
| **Bookmark / Watch Status** | `Cmd + B` | — |
| **Close / Back** | `Esc` | `Cmd + W` |

---

## 7. Modern SwiftUI 6 Primitives (macOS 15+ Sequoia)

This project leverages Apple’s latest SwiftUI capabilities to achieve flawless desktop ergonomics:

### 7.1 Unclipped Fluid Shelves (`.scrollClipDisabled`)
To ensure that card hover scaling (`1.04x`) never clips against the top or bottom of the horizontal scroll viewport:
```swift
ScrollView(.horizontal, showsIndicators: false) {
    LazyHStack(spacing: 16) {
        ForEach(continueWatchingItems) { item in
            ContinueWatchingCard(item: item)
        }
    }
    .padding(.horizontal, 24)
}
.scrollTargetBehavior(.viewAligned)
.scrollClipDisabled() // Allows squircle cards to pop gracefully on hover
```

### 7.2 Ambient Atmosphere with `MeshGradient`
The "Browse Categories" grid tiles utilize Apple's native `MeshGradient` for ultra-smooth multi-point ambient backdrops:
```swift
struct AmbientCategoryCard: View {
    let title: String
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    .purple, .indigo, .blue,
                    .blue.opacity(0.8), .indigo, .purple.opacity(0.6),
                    .black, .indigo.opacity(0.4), .blue
                ]
            )
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .padding(14)
        }
        .frame(width: 160, height: 240)
    }
}
```

### 7.3 Native Micro-Interactions (`.symbolEffect`)
Interactive buttons use SF Symbols animation effects:
```swift
Button(action: togglePlay) {
    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        .symbolEffect(.bounce, value: isPlaying)
}
.buttonStyle(.plain)
```