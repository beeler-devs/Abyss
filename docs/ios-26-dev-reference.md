# iOS 26 Development Reference

> **Scope:** iOS 26 · SwiftUI 6 · Swift 6.2 · Xcode 26 · Liquid Glass Design System  
> **Last updated:** March 2026  
> **Minimum deployment target for new APIs:** iOS 26 (unless noted)

---

## Table of Contents

1. [Environment Setup](#1-environment-setup)
2. [Liquid Glass Design System](#2-liquid-glass-design-system)
3. [Core glassEffect API](#3-core-glasseffect-api)
4. [GlassEffectContainer & Morphing](#4-glasseffectcontainer--morphing)
5. [Toolbars in iOS 26](#5-toolbars-in-ios-26)
6. [Tab Bars & Navigation](#6-tab-bars--navigation)
7. [Sheets & Transitions](#7-sheets--transitions)
8. [SwiftUI New APIs](#8-swiftui-new-apis)
9. [@Animatable Macro](#9-animatable-macro)
10. [WebView (Native SwiftUI)](#10-webview-native-swiftui)
11. [Rich Text Editing with TextEditor + AttributedString](#11-rich-text-editing-with-texteditor--attributedstring)
12. [Swift Charts 3D](#12-swift-charts-3d)
13. [SF Symbols 7](#13-sf-symbols-7)
14. [UIKit ↔ SwiftUI Bridging](#14-uikit--swiftui-bridging)
15. [Architecture Patterns](#15-architecture-patterns)
16. [App Structure & Scene Management](#16-app-structure--scene-management)
17. [Navigation Patterns](#17-navigation-patterns)
18. [Data Flow & State Management](#18-data-flow--state-management)
19. [Concurrency (Swift 6.2)](#19-concurrency-swift-62)
20. [Performance & Rendering](#20-performance--rendering)
21. [Accessibility](#21-accessibility)
22. [Backward Compatibility Patterns](#22-backward-compatibility-patterns)
23. [Xcode 26 Features](#23-xcode-26-features)
24. [Icon Composer & App Icons](#24-icon-composer--app-icons)
25. [Design Guidelines & Do/Don't](#25-design-guidelines--dodont)
26. [Official Resources](#26-official-resources)

---

## 1. Environment Setup

### Requirements

| Tool | Version |
|------|---------|
| Xcode | 26+ |
| macOS | Tahoe 26+ |
| iOS Deployment Target (new APIs) | iOS 26 |
| Swift | 6.2 |

### Enabling Liquid Glass

Liquid Glass activates **automatically** when you recompile your existing app with Xcode 26. No code changes are needed for system-provided SwiftUI/UIKit components. Custom UI requires opt-in via the new APIs documented below.

```swift
// Build with Xcode 26 SDK → system components get glass automatically
// Custom elements require explicit adoption
```

### Conditional Compilation

```swift
// Availability check for iOS 26 APIs
if #available(iOS 26, *) {
    // Use Liquid Glass APIs
} else {
    // Fallback for iOS 18–25
}

// Compiler directive
#if swift(>=6.2)
// Swift 6.2 specific code
#endif
```

---

## 2. Liquid Glass Design System

### What Is Liquid Glass?

Liquid Glass is Apple's unified design language introduced at WWDC 2025, shipping in iOS 26, iPadOS 26, macOS Tahoe 26, watchOS 26, tvOS 26, and visionOS 4. It is Apple's most significant visual redesign since iOS 7 (2013).

**Core properties of the material:**
- **Refracts** content from below it
- **Reflects** light and surrounding content
- **Lens effect** along edges — gives depth and motion
- **Adaptive** — adjusts to Light, Dark, Increased Contrast appearances
- **Dynamic** — transforms during interaction (scroll, press, expand)

### Appearance Modes

| Mode | Behavior |
|------|----------|
| Light | Bright, translucent glass |
| Dark | Deep, dimmed glass |
| Tinted | User accent color applied |
| Clear | Maximum transparency, glassy aesthetic emphasized |
| Increased Contrast | Enhanced borders and reduced transparency for accessibility |

### Design Philosophy

1. **Glass belongs on the navigation layer only** — toolbars, tab bars, sidebars, overlays
2. **Never place glass on content** — it occludes and distracts
3. **Never stack glass on glass** — creates visual noise
4. **Trust the system** — accessibility adaptations are automatic
5. **Tint sparingly** — only on primary/call-to-action elements

---

## 3. Core glassEffect API

### Signature

```swift
func glassEffect<S: Shape>(
    _ glass: Glass = .regular,
    in shape: S = DefaultGlassEffectShape, // capsule
    isEnabled: Bool = true
) -> some View
```

### Glass Variants

```swift
Glass.regular   // Default adaptive variant — use for most controls
Glass.clear     // Higher transparency — use over rich backgrounds
Glass.identity  // No effect (opt-out, useful for conditional logic)
```

### Glass Modifiers

```swift
// Add a semantic color tint (call-to-action only)
glass.tint(_ color: Color) -> Glass

// Enable interactive press/bounce/shimmer behavior (iOS only)
glass.interactive() -> Glass
```

> **Note:** Modifier order does **not** matter — `.tint(.blue).interactive()` equals `.interactive().tint(.blue)`.

### Usage Examples

```swift
import SwiftUI

// --- Minimal ---
Text("Hello, Liquid Glass!")
    .padding()
    .glassEffect()

// --- Custom shape ---
Button("Action") { }
    .glassEffect(.regular, in: .rect(cornerRadius: 12))

// --- Circle shape ---
Image(systemName: "heart.fill")
    .padding(12)
    .glassEffect(.regular, in: .circle)

// --- With tint (primary action only) ---
Button("Save") { }
    .padding()
    .glassEffect(.regular.tint(.blue))

// --- Interactive (bounces/shimmers on tap) ---
Button("Tap me") { }
    .padding()
    .glassEffect(.regular.interactive())

// --- Combined ---
Button("Primary") { }
    .padding()
    .glassEffect(.regular.tint(.orange).interactive())

// --- Clear variant over image ---
ZStack {
    Image("hero-photo").resizable().scaledToFill()
    HStack { /* controls */ }
        .padding()
        .glassEffect(.clear)
}
```

### Button Styles

```swift
// Translucent glass button
Button("Secondary") { }
    .buttonStyle(.glass)

// Opaque prominent button (full tint surface)
Button("Primary") { }
    .buttonStyle(.glassProminent)
    .tint(.blue)
```

### What NOT to Do

```swift
// ❌ Do not add .blur, .opacity, or .background on a glassEffect view
Text("Bad")
    .glassEffect()
    .background(Color.white)      // ❌ Breaks glass rendering

// ❌ Do not place solid fills directly behind glass
ZStack {
    Color.white                    // ❌
    Text("Bad").glassEffect()
}

// ❌ Do not stack glass on glass
VStack {
    Text("A").glassEffect()
    Text("B").glassEffect()        // ❌ Use GlassEffectContainer instead
}
```

---

## 4. GlassEffectContainer & Morphing

### What It Does

`GlassEffectContainer` is a SwiftUI container that groups multiple `.glassEffect()` views so they:
- Share blur and lighting render pass (performance optimization)
- Blend/merge when they are close together (morphing)
- Animate fluid shape transitions between states

### Basic Usage

```swift
import SwiftUI

struct BasicGlassExample: View {
    var body: some View {
        ZStack {
            Image("background").resizable().ignoresSafeArea()

            GlassEffectContainer {
                HStack(spacing: 20) {
                    Button("Home") { }.glassEffect()
                    Button("Settings") { }.glassEffect()
                    Button("Profile") { }.glassEffect()
                }
                .padding()
            }
        }
    }
}
```

### Controlling Morph Threshold

```swift
// Elements within `spacing` points morph/blend into one shape
GlassEffectContainer(spacing: 30) {
    HStack(spacing: 20) {
        Button("A") { }.glassEffect()
        Button("B") { }.glassEffect()
        // A and B are 20pt apart < 30pt threshold → they will merge
    }
}
```

### Morphing Animations with glassEffectID

Use `glassEffectID(_:in:)` to enable fluid morphing transitions as views appear/disappear:

```swift
struct ExpandingMenu: View {
    @State private var isExpanded = false
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 16) {
                Button {
                    withAnimation(.spring()) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "xmark" : "plus")
                        .frame(width: 50, height: 50)
                }
                .glassEffect()
                .glassEffectID("main", in: namespace)

                if isExpanded {
                    Button("Camera") { }
                        .glassEffect()
                        .glassEffectID("camera", in: namespace)

                    Button("Photos") { }
                        .glassEffect()
                        .glassEffectID("photos", in: namespace)

                    Button("Files") { }
                        .glassEffect()
                        .glassEffectID("files", in: namespace)
                }
            }
        }
    }
}
```

### Hiding Shared Background

```swift
// Remove a specific toolbar item from its group's shared glass background
ToolbarItem(placement: .topBarTrailing) {
    Button("Action") { }
        .sharedBackgroundVisibility(.hidden)
}
```

---

## 5. Toolbars in iOS 26

### Automatic Glass

All toolbars built with standard SwiftUI `toolbar` modifier **automatically get Liquid Glass** when compiled with Xcode 26. No migration needed for the glass surface itself.

### Toolbar Item Grouping

Items in the same placement group automatically share a glass background capsule. Use `ToolbarSpacer` to split items into separate groups:

```swift
import SwiftUI

struct MyToolbar: ToolbarContent {
    var body: some ToolbarContent {
        // Cancel on the left — its own group
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") { }
        }

        // Primary actions grouped together
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Draw", systemImage: "pencil") { }
            Button("Erase", systemImage: "eraser") { }
        }

        // Flexible space separates groups
        ToolbarSpacer(.flexible)

        // Confirmation action — its own group, gets glassProminent style
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", systemImage: "checkmark") { }
        }
    }
}
```

### ToolbarSpacer

```swift
// Fixed spacing — system-determined default space
ToolbarSpacer(.fixed, placement: .topBarTrailing)

// Fixed spacing with explicit size
ToolbarSpacer(.fixed, spacing: 24, placement: .topBarTrailing)

// Flexible space — expands to push items apart
ToolbarSpacer(.flexible)
```

### Tinting Toolbar Items

```swift
// Tint individual button (affects symbol color)
ToolbarItem(placement: .topBarLeading) {
    Button("Alerts", systemImage: "bell") { }
        .tint(.yellow)
        .badge(3)
}

// Full-surface tint (use glassProminent button style)
ToolbarItem(placement: .confirmationAction) {
    Button("Done", systemImage: "checkmark") { }
        .buttonStyle(.glassProminent)
        .tint(.blue)
}
```

### Scroll Effect

Toolbar glass automatically transitions as the user scrolls — it lifts and gains separation from app content. You can control this:

```swift
// Hide the glass background on scroll (for custom handling)
.toolbar {
    ToolbarItem(placement: .principal) {
        Text("Title")
            .sharedBackgroundVisibility(.hidden)
    }
}
```

### Backward Compatibility Pattern

```swift
struct ToolbarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26, *) {
            Label(configuration) // iOS 26: symbol-first, label is hidden
        } else {
            Label(configuration)
                .labelStyle(.titleOnly) // iOS 18: show text label
        }
    }
}

// Mark obsolete in iOS 26 to get compiler warning to remove it later
@available(iOS, introduced: 18, obsoleted: 26, message: "Remove in iOS 26")
extension LabelStyle where Self == ToolbarLabelStyle {
    static var toolbar: Self { .init() }
}
```

### ToolbarItem Placements Reference

| Placement | Location | Glass Behavior |
|-----------|----------|----------------|
| `.topBarLeading` | Nav bar left | Grouped in leading glass capsule |
| `.topBarTrailing` | Nav bar right | Grouped in trailing glass capsule |
| `.primaryAction` | Nav bar trailing | Prominent glass |
| `.confirmationAction` | Trailing — gets glassProminent | Tinted glass |
| `.cancellationAction` | Leading | Standard glass |
| `.bottomBar` | Bottom toolbar | Own glass bar |
| `.principal` | Center nav bar | Custom rendering |

---

## 6. Tab Bars & Navigation

### Tab Bar in iOS 26

Tab bars automatically adopt Liquid Glass. When the user scrolls down, they **shrink** to keep focus on content. When the user scrolls back up, they **fluidly expand**.

```swift
TabView {
    Tab("Home", systemImage: "house") {
        HomeView()
    }
    Tab("Search", systemImage: "magnifyingglass", role: .search) {
        SearchView()
    }
    Tab("Profile", systemImage: "person") {
        ProfileView()
    }
}
// Control tab bar minimize behavior
.tabBarMinimizeBehavior(.onScrollDown)

// Add a persistent bottom accessory (e.g. mini player)
.tabViewBottomAccessory {
    MiniPlayerView()
}
```

### Tab Roles

```swift
Tab("Search", systemImage: "magnifyingglass", role: .search) {
    SearchView()
}
// Compact search toolbar (collapses when not focused)
.searchToolbarBehavior(.minimize)
```

### NavigationSplitView (iPad / macOS)

Automatically becomes a Liquid Glass sidebar on iPad and macOS. Refracts content behind it while reflecting the user's wallpaper:

```swift
NavigationSplitView {
    SidebarView()
} detail: {
    DetailView()
}
// Glass sidebar is automatic — no extra API needed
```

### NavigationStack

```swift
NavigationStack {
    ContentView()
        .navigationTitle("Title")
        .toolbar { MyToolbar() }
}
```

---

## 7. Sheets & Transitions

### Liquid Glass Sheets (iOS 26)

Partial height sheets automatically use a floating Liquid Glass background with rounded corners matching the device shape. At smaller detents, bottom edges curve in. At large/full detents, the glass transitions to opaque and anchors to the screen edge.

```swift
// Basic floating glass sheet
ContentView()
    .sheet(isPresented: $showSheet) {
        SheetContent()
            .presentationDetents([.medium, .large])
        // ✅ Do NOT use presentationBackground() — let Liquid Glass shine
    }
```

### Sheet Morphing from Toolbar Button

Sheets can morph out of the button that presents them:

```swift
struct ContentView: View {
    @Namespace private var transition
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            BirdImage()
                .toolbar {
                    ToolbarSpacer(placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("Info", systemImage: "info") {
                            showInfo = true
                        }
                    }
                    .matchedTransitionSource(id: "info", in: transition)
                }
                .sheet(isPresented: $showInfo) {
                    InfoView()
                        .presentationDetents([.medium, .large])
                        .navigationTransition(.zoom(sourceID: "info", in: transition))
                }
        }
    }
}
```

### Dialog Morphing

Dialogs (alerts, confirmation dialogs) **automatically morph out of the buttons that present them** in iOS 26. No extra code required when using `.confirmationDialog` or `.alert`.

### Zoom Transition

```swift
// Zoom navigation transition — e.g. list row to detail
NavigationLink {
    DetailView()
        .navigationTransition(.zoom(sourceID: item.id, in: namespace))
} label: {
    RowView(item: item)
        .matchedTransitionSource(id: item.id, in: namespace)
}
```

---

## 8. SwiftUI New APIs

### Complete New API Checklist (iOS 26)

| API | Description |
|-----|-------------|
| `.glassEffect()` | Apply Liquid Glass material to any view |
| `GlassEffectContainer` | Group glass views for shared rendering + morphing |
| `.glassEffectID(_:in:)` | Enable identity-based morphing animations |
| `.buttonStyle(.glass)` | Translucent glass button |
| `.buttonStyle(.glassProminent)` | Opaque tinted glass button |
| `ToolbarSpacer(.fixed/.flexible)` | Split toolbar item groups |
| `.sharedBackgroundVisibility(.hidden)` | Remove item from group glass |
| `.tabBarMinimizeBehavior(.onScrollDown)` | Shrink tab bar on scroll |
| `.tabViewBottomAccessory { }` | Persistent accessory below tab bar |
| `Tab(role: .search)` | Search-role tab |
| `.searchToolbarBehavior(.minimize)` | Compact search toolbar |
| `WebView(url:)` | Native SwiftUI web view |
| `WebPage` | `@Observable` class for WebView state |
| `TextEditor(text: $attributedString)` | Rich text editing |
| `AttributedTextSelection` | Selection with formatting attributes |
| `AttributedTextFormattingDefinition` | Custom formatting constraints protocol |
| `@Animatable` | Macro to auto-synthesize `animatableData` |
| `@AnimatableIgnored` | Exclude a property from animation |
| `Chart3D { }` | 3D Swift Charts |
| `SurfacePlot` | 3D surface visualization |
| `UIHostingSceneDelegate` | Bridge SwiftUI scenes into UIKit |
| `.safeAreaBar { }` | Safe area bar with blur |
| `.scrollEdgeEffectStyle(_:)` | Scroll edge style |
| `.controlSize(.extraLarge)` | XL control size |
| `.containerConcentric` | Concentric rectangle shape |
| `SliderTick` | Tick marks on sliders |
| `.sliderThumbVisibility(_:)` | Control slider thumb display |
| `.dragContainer` | Enhanced drag-and-drop |
| `.windowResizeAnchor(_:)` | iPad window resize anchor |
| `.matchedTransitionSource(id:in:)` | Zoom transition source |
| `.navigationTransition(.zoom(...))` | Zoom navigation transition |

### Safe Area Bar

```swift
ScrollView {
    ContentView()
}
.safeAreaBar(edge: .bottom) {
    MiniPlayerView()
}
.scrollEdgeEffectStyle(.soft, for: .bottom)
```

### Extra Large Controls

```swift
Button("Big Action") { }
    .controlSize(.extraLarge)
    .buttonStyle(.glassProminent)
```

### Slider Ticks

```swift
Slider(value: $volume, in: 0...100, step: 10) {
    Text("Volume")
} minimumValueLabel: {
    Text("0")
} maximumValueLabel: {
    Text("100")
} ticks: {
    SliderTickContentForEach(stride(from: 0, through: 100, by: 10)) { value in
        SliderTick()
    }
}
```

---

## 9. @Animatable Macro

### Problem It Solves

Before iOS 26, custom animatable shapes/view modifiers required boilerplate:

```swift
// ❌ iOS 17 — manual boilerplate
struct ProgressRing: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    // ...
}
```

### iOS 26 — @Animatable

```swift
// ✅ iOS 26 — macro synthesizes animatableData automatically
@Animatable
struct ProgressRing: Shape {
    var progress: Double
    // animatableData synthesized for `progress`
}

// Multiple animatable properties (uses AnimatablePair internally)
@Animatable
struct CoolShape: Shape {
    var width: CGFloat
    var angle: Angle
    @AnimatableIgnored var isOpaque: Bool  // excluded from animation
}
```

### Works With

- `Shape`
- `ViewModifier`
- `TextRenderer`
- Any `struct` or `class` conforming to `Animatable`

```swift
@Animatable
struct WaveModifier: ViewModifier {
    var phase: Double
    var amplitude: Double

    func body(content: Content) -> some View {
        content.offset(y: sin(phase) * amplitude)
    }
}
```

---

## 10. WebView (Native SwiftUI)

### Before iOS 26

```swift
// ❌ Required UIViewRepresentable wrapper
struct WebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { WKWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.load(URLRequest(url: url))
    }
}
```

### iOS 26 — Native WebView

```swift
import SwiftUI

// ✅ Simple URL
WebView(url: URL(string: "https://apple.com")!)

// ✅ With navigation callbacks
WebView(url: url)
    .webViewNavigationDelegate(
        didStartLoading: { isLoading = true },
        didFinishLoading: { isLoading = false }
    )

// ✅ Open link in-app (new parameter)
@Environment(\.openURL) var openURL
Button("Open") {
    openURL(url, inApp: true) // inApp parameter is new in iOS 26
}
```

### WebPage — Observable State

```swift
import SwiftUI

@Observable
class MyWebPage: WebPage {
    // Observe navigation events
}

struct BrowserView: View {
    @State private var page = WebPage()
    @State private var isLoading = false

    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
            }
            WebView(webPage: page)
                .onAppear {
                    page.load(URLRequest(url: url))
                }
                .onChange(of: page.currentNavigationEvent) { _, event in
                    switch event {
                    case .started: isLoading = true
                    case .finished, .failed: isLoading = false
                    default: break
                    }
                }
        }
    }
}
```

---

## 11. Rich Text Editing with TextEditor + AttributedString

### Before iOS 26

Had to wrap `UITextView` in `UIViewRepresentable`. No native SwiftUI rich text.

### iOS 26 — Native Rich Text

```swift
import SwiftUI

// ✅ Basic — just change binding type to AttributedString
struct RichEditorView: View {
    @State private var text = AttributedString()

    var body: some View {
        TextEditor(text: $text)
    }
}
```

### With Selection and Format Toolbar

```swift
struct FormattedEditor: View {
    @State private var text = AttributedString()
    @State private var selection = AttributedTextSelection()

    var body: some View {
        VStack {
            FormatToolbar(text: $text, selection: $selection)
            TextEditor(text: $text, selection: $selection)
                .textEditorStyle(.richText)
                .richTextToolbar(.visible) // Show system format toolbar
        }
    }
}
```

### Inspecting and Applying Attributes

```swift
// Read typing attributes at cursor position
let typingAttributes = selection.typingAttributes(in: text)
let isBold = typingAttributes.font?.isBold ?? false

// Apply formatting to selection
text.transformAttributes(in: &selection) { attributes in
    attributes.font = attributes.font?.bold()
}
```

### Building AttributedString Programmatically

```swift
// Compose from parts
var greeting = AttributedString("Hello, ")
var name = AttributedString("Aarush")
name.font = .body.bold()
name.foregroundColor = .blue
greeting.append(name)

// From Markdown
let attributed = try AttributedString(
    markdown: "**Bold** and *italic* with a [link](https://example.com)",
    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
)

// Insert at position
var a = AttributedString("Hello, world")
if let commaIndex = a.firstIndex(of: ",") {
    a.insert(AttributedString(" dear"), at: a.index(after: commaIndex))
}
```

### Custom Formatting Definition

```swift
struct MyFormattingDefinition: AttributedTextFormattingDefinition {
    // Define allowed attributes and constraints
    // AttributedTextValueConstraint automatically transforms attributes → visual styling
}
```

### Font Resolution in Editors

```swift
// Use fontResolutionContext to resolve adaptive fonts correctly
@Environment(\.fontResolutionContext) var fontResolutionContext

let resolvedFont = typingAttributes.font?.resolved(in: fontResolutionContext)
```

---

## 12. Swift Charts 3D

iOS 26 adds 3D chart support via `Chart3D`:

```swift
import Charts

Chart3D {
    SurfacePlot(
        x: "X Axis", y: "Y Axis", z: "Value"
    ) { x, y in
        sin(x) * cos(y)
    }
}
// Camera, lighting, materials, rendering properties configurable
.chart3DCamera(distance: 5, azimuth: .degrees(45), elevation: .degrees(30))
```

---

## 13. SF Symbols 7

- **6,900+ symbols**
- New **draw-on** animations — particularly beautiful with checkboxes
- **Gradient support** on symbols
- **New variable value animations**

```swift
import SwiftUI

// Animated symbol
Image(systemName: "checkmark.circle.fill")
    .symbolEffect(.bounce, value: isChecked)

// Draw-on animation (new in iOS 26)
Image(systemName: "checkmark")
    .symbolEffect(.drawOn, isActive: isAnimating)

// Variable color with gradient
Image(systemName: "speaker.wave.3")
    .symbolRenderingMode(.hierarchical)
    .foregroundStyle(.blue.gradient)

// New symbol effect types
.symbolEffect(.wiggle)
.symbolEffect(.rotate)
.symbolEffect(.breathe)
```

---

## 14. UIKit ↔ SwiftUI Bridging

### UIHostingSceneDelegate (New in iOS 26)

Bridge a full SwiftUI scene into a UIKit scene lifecycle:

```swift
// AppDelegate / SceneDelegate setup
class MySceneDelegate: UIHostingSceneDelegate {
    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    override var rootView: some View {
        MainAppView()
    }
}
```

Previously only `UIHostingController` was available (for individual views). `UIHostingSceneDelegate` handles **full scene** integration.

### UIHostingController (Still Available)

```swift
let hostingVC = UIHostingController(rootView: SwiftUIView())
present(hostingVC, animated: true)
```

### UIViewRepresentable (Still Available)

```swift
struct MapViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView {
        MKMapView()
    }
    func updateUIView(_ uiView: MKMapView, context: Context) { }
}
```

### PaperKit

New framework in iOS 26 — **does not have SwiftUI wrappers** (use UIViewRepresentable).

---

## 15. Architecture Patterns

### Recommended: Observable + SwiftUI

```swift
import Observation

@Observable
class AppModel {
    var user: User?
    var settings = AppSettings()
    var isLoading = false

    func loadUser() async {
        isLoading = true
        defer { isLoading = false }
        user = await UserService.fetch()
    }
}

@main
struct MyApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isLoading {
            ProgressView()
        } else {
            UserView(user: model.user)
        }
    }
}
```

### SwiftData

```swift
import SwiftData

@Model
class Trip {
    var name: String
    var destination: String
    var startDate: Date

    init(name: String, destination: String, startDate: Date) {
        self.name = name
        self.destination = destination
        self.startDate = startDate
    }
}

// In App
.modelContainer(for: Trip.self)

// In View
@Query(sort: \Trip.startDate) private var trips: [Trip]
@Environment(\.modelContext) private var context
```

### MVVM with @Observable

```swift
@Observable
class HomeViewModel {
    private(set) var items: [Item] = []
    var searchText = ""
    var errorMessage: String?

    var filteredItems: [Item] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func load() async {
        do {
            items = try await ItemService.fetchAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

---

## 16. App Structure & Scene Management

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // macOS: Additional windows
        #if os(macOS)
        Window("Settings", id: "settings") {
            SettingsView()
        }
        #endif
    }
}
```

### Multi-Window (iPad)

```swift
// Open new window
@Environment(\.openWindow) private var openWindow

Button("Open Detail") {
    openWindow(id: "detail", value: item.id)
}

// Resize anchor (new in iOS 26)
WindowGroup("Detail", id: "detail", for: Item.ID.self) { $id in
    DetailView(id: id)
}
.windowResizeAnchor(.topLeading)
```

---

## 17. Navigation Patterns

### NavigationStack

```swift
struct RootView: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ItemListView()
                .navigationDestination(for: Item.self) { item in
                    ItemDetailView(item: item)
                }
                .navigationDestination(for: String.self) { str in
                    StringDetailView(value: str)
                }
        }
    }
}

// Programmatic navigation
path.append(selectedItem)
path.removeLast()
path = NavigationPath()  // Pop to root
```

### NavigationSplitView

```swift
struct MainView: View {
    @State private var selectedItem: Item?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedItem)
        } detail: {
            if let item = selectedItem {
                DetailView(item: item)
            } else {
                Text("Select an item")
            }
        }
    }
}
```

---

## 18. Data Flow & State Management

### Property Wrappers Reference

| Wrapper | Scope | Use Case |
|---------|-------|----------|
| `@State` | Local view | Simple local state |
| `@Binding` | Passed down | Two-way binding from parent |
| `@Observable` | Any class | App-wide model (replaces `@ObservableObject`) |
| `@Environment` | View hierarchy | Shared values/models via environment |
| `@EnvironmentObject` | Legacy | `ObservableObject` in environment |
| `@AppStorage` | UserDefaults | Persisted scalar values |
| `@SceneStorage` | Scene | State restored on scene restoration |
| `@Query` | SwiftData | Reactive persistent queries |
| `@FocusState` | Focus system | Keyboard/focus management |

### Passing Observable Models

```swift
// Inject
.environment(myModel)

// Consume
@Environment(MyModel.self) private var model

// Binding into Observable (iOS 17+ pattern, still valid)
@Bindable var model: MyModel
TextField("Name", text: $model.name)
```

---

## 19. Concurrency (Swift 6.2)

### Actors & MainActor

```swift
@Observable
@MainActor
class ViewModel {
    var items: [Item] = []

    func load() async {
        // Already on MainActor — safe to update @Observable properties
        items = await Task.detached {
            await ItemService.fetch() // Runs off main thread
        }.value
    }
}
```

### Structured Concurrency

```swift
func loadAll() async {
    async let users = UserService.fetchAll()
    async let products = ProductService.fetchAll()

    let (u, p) = await (users, products)
    self.users = u
    self.products = p
}
```

### Swift 6 Data Race Safety

Swift 6 enforces data race safety at compile time via `Sendable` checking:

```swift
// Sendable model — safe to cross actor boundaries
struct UserData: Sendable {
    let id: UUID
    let name: String
}

// Swift 6 verifies this is safe
@Observable class TripStore {
    var trips: [Trip] = []

    func loadTrips() async {
        trips = await TripService.fetchTrips()
        // Compiler verifies no data races in concurrent code
    }
}
```

### AsyncStream

```swift
func watchUpdates() -> AsyncStream<Item> {
    AsyncStream { continuation in
        let task = Task {
            for await update in service.updates {
                continuation.yield(update)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// Consume in SwiftUI
.task {
    for await item in viewModel.watchUpdates() {
        latestItem = item
    }
}
```

---

## 20. Performance & Rendering

### SwiftUI Performance Improvements (iOS 26)

iOS 26 improves UI update scheduling, reducing dropped frames at high frame rates. Nested `ScrollView` with `LazyStack` now properly defers loading:

```swift
// Nested scrollviews — lazy loading works correctly in iOS 26
ScrollView(.horizontal) {
    LazyHStack {
        ForEach(photoSets) { set in
            ScrollView(.vertical) {
                LazyVStack {
                    ForEach(set.photos) { photo in
                        PhotoView(photo: photo)
                    }
                }
            }
        }
    }
}
```

### Lazy Loading

```swift
// Always use lazy containers for large data sets
LazyVStack { ... }
LazyHStack { ... }
LazyVGrid(columns: columns) { ... }
List { ... }                          // List is lazy by default
```

### Image Loading

```swift
// Use AsyncImage for network images
AsyncImage(url: url) { phase in
    switch phase {
    case .empty: ProgressView()
    case .success(let img): img.resizable().scaledToFill()
    case .failure: Image(systemName: "photo")
    @unknown default: EmptyView()
    }
}
.frame(width: 100, height: 100)
.clipped()
```

### Instruments

Use Xcode 26's Instruments for:
- **CPU Bottleneck Analysis** — new in Xcode 26
- **Power Profiler** — battery impact analysis
- **SwiftUI performance tracking** — frame timing per view

---

## 21. Accessibility

### Liquid Glass Accessibility

Liquid Glass **automatically adapts** to:
- **Increased Contrast** — enhanced borders, reduced transparency
- **Reduce Transparency** — glass becomes opaque
- **Dynamic Type** — all text scales correctly
- **VoiceOver** — glass surfaces have no semantic impact on accessibility tree

No additional code is needed for basic accessibility compliance with Liquid Glass.

### VoiceOver

```swift
Text("Profile")
    .accessibilityLabel("User profile button")
    .accessibilityHint("Double tap to open your profile")
    .accessibilityAddTraits(.isButton)

// Grouping
HStack {
    Image(systemName: "star.fill")
    Text("Favorites")
}
.accessibilityElement(children: .combine)
.accessibilityLabel("Favorites")
```

### Dynamic Type

```swift
// Always use system fonts — they scale automatically
Text("Title").font(.title)
Text("Body").font(.body)

// For custom fonts, use scaled metrics
@ScaledMetric(relativeTo: .body) var iconSize: CGFloat = 20
```

---

## 22. Backward Compatibility Patterns

### Availability Guards

```swift
// View with iOS 26 enhancement
struct MyButton: View {
    var body: some View {
        if #available(iOS 26, *) {
            Button("Action") { }
                .glassEffect(.regular.interactive())
        } else {
            Button("Action") { }
                .buttonStyle(.bordered)
        }
    }
}
```

### Conditional Glass Effect

```swift
extension View {
    @ViewBuilder
    func adaptiveGlass() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect()
        } else {
            self.background(.regularMaterial)
                .clipShape(.capsule)
        }
    }
}

// Usage
Button("Action") { }
    .padding()
    .adaptiveGlass()
```

### Deliquify Modifier (Tab Bar Fade Fallback)

When you need to fade content under a tab bar on older iOS versions:

```swift
struct TabBarFadeModifier: ViewModifier {
    let fadeLocation: CGFloat = 0.4
    let opacity: CGFloat = 0.85
    let backgroundColor: Color = Color(.systemBackground)

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            ZStack {
                content
                if geometry.safeAreaInsets.bottom > 10 {
                    VStack {
                        Spacer()
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: backgroundColor.opacity(opacity), location: fadeLocation)
                            ]),
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: geometry.safeAreaInsets.bottom)
                        .allowsHitTesting(false)
                        .offset(y: geometry.safeAreaInsets.bottom)
                    }
                }
            }
        }
    }
}

extension View {
    func deliquify() -> some View {
        modifier(TabBarFadeModifier())
    }
}
```

---

## 23. Xcode 26 Features

| Feature | Detail |
|---------|--------|
| **Faster Launch** | Projects load up to 40% quicker |
| **Modular Size** | Downloads only components you need |
| **Built-in AI Assistant** | Inline code generation, bug fixes, documentation |
| **Live Previews** | Debug SwiftUI in real-time with animations |
| **Liquid Glass Toolkit** | Test translucency, blur, motion natively in canvas |
| **Icon Composer** | Multi-layered adaptive icon creation (see §24) |
| **Xcode Cloud 2025** | Faster CI, AI-generated TestFlight release notes |
| **Interactive Documentation** | Live code examples run inside Xcode |
| **Semantic Search** | Natural language API search |

### Swift 6 Compiler in Xcode 26

- Full data race safety enforcement at compile time
- Better error messages for `Sendable` violations
- Improved actor isolation diagnostics

---

## 24. Icon Composer & App Icons

Icon Composer is a new tool bundled with Xcode 26 for creating multi-layered adaptive app icons.

### Key Capabilities

- Single design → assets for iPhone, iPad, Mac, Apple Watch
- Supports all appearance modes: Light, Dark, Tinted, Clear
- Produces Liquid Glass icon rendering automatically
- Same workflow Apple used to update all system icons

### Icon Modes

| Mode | Use Case |
|------|----------|
| Light | Default appearance |
| Dark | Dark Mode |
| Tinted | User accent color applied |
| Clear | Maximum glass transparency (Home Screen) |

### Design Considerations

- Design from the inside out — background → middle layer → foreground
- Use semi-transparent materials for depth
- Test all four appearance modes before shipping
- Export SVG layers; Icon Composer handles rendering

---

## 25. Design Guidelines & Do/Don't

### Liquid Glass Do

| Do | Reason |
|----|--------|
| Use `GlassEffectContainer` for multiple nearby glass elements | Shared rendering, morphing, performance |
| Apply `.glassEffect()` only on navigation/overlay elements | Glass belongs on the navigation layer |
| Use `.tint()` only for primary actions | Tint conveys semantic meaning |
| Let sheets use default glass background | `presentationDetents` + no `presentationBackground` |
| Ensure content behind glass has visual interest | Glass refracts — plain solid backgrounds look flat |
| Use `.interactive()` for touch-target controls | Creates delightful bounce/shimmer on press |

### Liquid Glass Don't

| Don't | Reason |
|-------|--------|
| Stack glass on glass | Visual noise, rendering artifacts |
| Add `.background`, `.blur`, or `.opacity` on glass views | Breaks the glass rendering pipeline |
| Apply glass to content cards or list rows | Glass belongs on navigation, not content |
| Use solid fills directly behind glass | Defeats the refraction effect |
| Apply `presentationBackground` to sheets | Overrides Liquid Glass sheet material |
| Add glass to every element | Dilutes meaning, increases visual clutter |
| Use `.tint()` for decorative color | Tint = semantic CTA only |

### General SwiftUI Best Practices

1. Use system components wherever possible — they get Liquid Glass for free
2. Rebuild with Xcode 26 SDK first — assess what changes before customizing
3. Review foreground element contrast against dynamic glass backgrounds
4. Prefer `NavigationStack` over deprecated `NavigationView`
5. Use `@Observable` over `ObservableObject` for new code
6. Always lazy-load large lists with `LazyVStack`/`LazyHStack` or `List`
7. Test on device — glass effects look different in Simulator

---

## 26. Official Resources

### WWDC 2025 Sessions

| Session | Title |
|---------|-------|
| 219 | Meet Liquid Glass |
| 323 | Build a SwiftUI app with the new design |
| 310 | Build an AppKit app with the new design |
| — | Get to know the new design system |
| — | Create icons with Icon Composer |

### Apple Documentation

- [GlassEffectContainer — Apple Developer Docs](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [Human Interface Guidelines — Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Technology Overviews — WWDC 2025](https://developer.apple.com/documentation)
- [Landmarks: Building an app with Liquid Glass (sample code)](https://developer.apple.com/documentation)

### Design Resources

- [Apple Design Resources](https://developer.apple.com/design/resources/) — Sketch Library, App Icon Templates
- [SF Symbols 7](https://developer.apple.com/sf-symbols/) — 6,900+ symbols
- [New Design Gallery](https://developer.apple.com/design/new-design-gallery/)

### Community References

| Resource | URL |
|----------|-----|
| iOS 26 Liquid Glass Reference | https://github.com/conorluddy/LiquidGlassReference |
| iOS 26 by Examples | https://github.com/artemnovichkov/iOS-26-by-Examples |
| SwiftUI iOS26 Showcase (60+ examples) | https://github.com/muhittincamdali/SwiftUI-iOS26-Showcase |
| Awesome Liquid Glass | https://github.com/GetStream/awesome-liquid-glass |
| Swift with Majid — Glassifying toolbars | https://swiftwithmajid.com/2025/07/01/glassifying-toolbars-in-swiftui/ |
| Nil Coalescing — Liquid Glass sheets | https://nilcoalescing.com/blog/PresentingLiquidGlassSheetsInSwiftUI/ |
| Hacking with Swift — What's new in SwiftUI iOS 26 | https://www.hackingwithswift.com/articles/278/whats-new-in-swiftui-for-ios-26 |
| Create with Swift — iOS 26 roundup | https://www.createwithswift.com/wwdc-2025-whats-new-for-the-apple-community/ |

---

*This document covers iOS 26 / Xcode 26 / Swift 6.2 as of March 2026. Always verify against the latest Apple Developer Documentation for the most current API signatures.*
