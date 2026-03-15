# macOS Tahoe 26 — SwiftUI Design System Reference
> Complete guide for Claude Code: building and reworking macOS apps with the Liquid Glass design language (WWDC 2025 / macOS 26 / Xcode 26).

---

## Table of Contents
1. [Core Philosophy](#1-core-philosophy)
2. [Window & Corner Radius](#2-window--corner-radius)
3. [Liquid Glass — The Material](#3-liquid-glass--the-material)
4. [glassEffect API Reference](#4-glasseffect-api-reference)
5. [GlassEffectContainer](#5-glasseffectcontainer)
6. [Buttons](#6-buttons)
7. [Toolbars](#7-toolbars)
8. [Sidebars & NavigationSplitView](#8-sidebars--navigationsplitview)
9. [Panels, Sheets & Popovers](#9-panels-sheets--popovers)
10. [Tab Views](#10-tab-views)
11. [Controls — Toggles, Sliders, Pickers](#11-controls--toggles-sliders-pickers)
12. [Menus](#12-menus)
13. [Typography & Color](#13-typography--color)
14. [Spacing & Layout Tokens](#14-spacing--layout-tokens)
15. [Morphing Animations with glassEffectID](#15-morphing-animations-with-glasseffectid)
16. [Accessibility](#16-accessibility)
17. [What You Get for Free (Zero Code)](#17-what-you-get-for-free-zero-code)
18. [Critical Anti-Patterns](#18-critical-anti-patterns)
19. [Compatibility & Deployment Targets](#19-compatibility--deployment-targets)
20. [Full App Skeleton](#20-full-app-skeleton)

---

## 1. Core Philosophy

macOS Tahoe 26 introduces **Liquid Glass**, Apple's broadest design update since iOS 7. The central principle is a strict **layer separation**:

- **Content layer**: Lists, tables, media, text — no glass applied here.
- **Navigation/control layer**: Toolbars, sidebars, floating buttons, tab bars — this is where Liquid Glass lives.

Liquid Glass is not a blur effect. It uses **lensing** — bending and concentrating light, not scattering it. The material dynamically refracts surrounding content, shows specular highlights, adapts to dark/light mode, and responds to interaction with scaling, bouncing, and shimmer.

**The golden rule:**
```swift
// ✅ CORRECT — glass floats above content
ZStack {
    List { /* content — no glass */ }
    VStack {
        Spacer()
        FloatingActionButton()
            .glassEffect(.regular.interactive())
    }
}

// ❌ WRONG — glass applied to content rows
List {
    ForEach(items) { item in
        Text(item.name)
            .glassEffect() // Never do this
    }
}
```

---

## 2. Window & Corner Radius

### Window Corner Radii in macOS Tahoe

macOS Tahoe significantly increased window corner radii. Crucially, the radius is **not uniform** — it varies by window type:

| Window Type | Approximate Corner Radius |
|---|---|
| Basic window (no toolbar, e.g. TextEdit) | ~16 pt |
| Toolbar window (e.g. Safari, Calculator) | ~26 pt |
| Sidebar window | Larger still, matches sidebar inset |

The system manages these automatically when you compile with Xcode 26. Do **not** hardcode corner radii on the window itself; use `containerConcentric` for inner elements.

### Container Concentricity

Inner elements must **concentric-nest** relative to their container so the corner relationships look correct. Use `.containerConcentric` rather than a hardcoded value:

```swift
// ✅ Concentric — automatically matches the enclosing container's radius
RoundedRectangle(cornerRadius: .containerConcentric, style: .continuous)

// In glassEffect
.glassEffect(.regular, in: .rect(cornerRadius: .containerConcentric))
```

### Recommended Corner Radius Values for Custom Elements

When you must specify a literal radius (e.g. in a custom drawn view):

| Element | Radius |
|---|---|
| Floating pill buttons / capsule controls | Use `.capsule` shape — don't hardcode |
| Circular icon buttons | Use `.circle` shape |
| Card / panel inner corner | 12–16 pt |
| Sheet inner corner | 16 pt |
| Large hero card | 20 pt |
| Window-level rounded rect | Let system decide; use `windowStyle(.hiddenTitleBar)` if going edge-to-edge |

**Always use `.continuous` style for all RoundedRectangle shapes:**
```swift
RoundedRectangle(cornerRadius: 16, style: .continuous)
```

---

## 3. Liquid Glass — The Material

### Three Material Variants

```swift
struct Glass {
    static var regular: Glass   // Default — adapts to any background
    static var clear: Glass     // High transparency — for media-rich backgrounds
    static var identity: Glass  // No effect — useful for conditional disable
}
```

**When to use each:**

| Variant | Use For | Requirement |
|---|---|---|
| `.regular` | Toolbars, floating buttons, panels, controls | General use |
| `.clear` | Controls floating over full-bleed photos/maps | Content behind is bold/bright; dimming layer acceptable |
| `.identity` | Conditionally disabling glass | — |

```swift
// Conditional glass (e.g. toggle off for accessibility)
.glassEffect(isGlassEnabled ? .regular : .identity)
```

### Tinting

Tint conveys **semantic meaning** (primary action, active state). Use sparingly. Do not tint for decoration.

```swift
// Primary action — tint with brand/semantic color
.glassEffect(.regular.tint(.blue))

// Active state indication
.glassEffect(.regular.tint(.orange.opacity(0.7)))

// Method chaining — order does not matter
.glassEffect(.regular.tint(.green).interactive())
```

### Interactive Modifier

Add `.interactive()` to floating controls that respond to touch/click. Enables scaling, bouncing, shimmer, and illumination effects on press.

```swift
Button("Action") { }
    .glassEffect(.regular.interactive())
```

> **macOS note**: `.interactive()` is primarily a mobile interaction affordance. On macOS, hover states and cursor feedback are handled automatically. You can still use `.interactive()` on macOS for button press animations.

---

## 4. glassEffect API Reference

### Full Signature

```swift
func glassEffect<S: Shape>(
    _ glass: Glass = .regular,
    in shape: S = DefaultGlassEffectShape,  // defaults to .capsule
    isEnabled: Bool = true
) -> some View
```

### Shape Options

```swift
// Capsule (default) — use for pill buttons, labels
.glassEffect()
.glassEffect(.regular, in: .capsule)

// Circle — icon buttons
.glassEffect(.regular, in: .circle)

// Rounded rectangle — cards, panels, badges
.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
.glassEffect(.regular, in: .rect(cornerRadius: 16))

// Concentric rounded rect — for elements inside containers/windows
.glassEffect(.regular, in: .rect(cornerRadius: .containerConcentric))

// Ellipse
.glassEffect(.regular, in: .ellipse)

// Custom shape
struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path { /* ... */ }
}
.glassEffect(.regular, in: DiamondShape())
```

### Placement Rule

Apply `.glassEffect()` **last** in your modifier chain:

```swift
// ✅ Correct — glassEffect is outermost
Text("Label")
    .font(.headline)
    .foregroundStyle(.primary)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .glassEffect()

// ❌ Wrong — modifiers applied after glass break the effect
Text("Label")
    .glassEffect()
    .padding()  // Do not do this
```

---

## 5. GlassEffectContainer

When multiple glass elements appear near each other, wrap them in a `GlassEffectContainer`. Glass cannot sample other glass — the container gives them a shared sampling region for visual correctness and enables morphing transitions.

### API

```swift
struct GlassEffectContainer<Content: View>: View {
    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content)
}
```

`spacing` is the **morphing threshold** in points: elements closer than this distance visually blend together.

### Basic Usage

```swift
GlassEffectContainer {
    HStack(spacing: 16) {
        Button("Edit", systemImage: "pencil") { }
            .glassEffect(.regular.interactive())
        Button("Share", systemImage: "square.and.arrow.up") { }
            .glassEffect(.regular.interactive())
        Button("Delete", systemImage: "trash") { }
            .glassEffect(.regular.tint(.red).interactive())
    }
}
```

### With Spacing Control

```swift
// Elements within 30 pts will morph together during transitions
GlassEffectContainer(spacing: 30) {
    HStack(spacing: 20) {
        PrimaryButton()
            .glassEffect()
        SecondaryButton()
            .glassEffect()
    }
}
```

### Zoom Controls Pattern (like Apple Maps)

```swift
@Namespace var ns

VStack(spacing: 0) {
    Button { zoomIn() } label: {
        Image(systemName: "plus")
            .frame(width: 44, height: 44)
    }
    .glassEffect(.regular.tint(.white.opacity(0.8)))
    .glassEffectUnion(id: "zoom", namespace: ns)

    Divider().frame(width: 44)

    Button { zoomOut() } label: {
        Image(systemName: "minus")
            .frame(width: 44, height: 44)
    }
    .glassEffect(.regular.tint(.white.opacity(0.8)))
    .glassEffectUnion(id: "zoom", namespace: ns)
}
```

---

## 6. Buttons

### Button Styles

macOS Tahoe adds two new glass-native button styles:

| Style | Appearance | Use Case |
|---|---|---|
| `.glass` | Translucent, shows background | Secondary actions |
| `.glassProminent` | Opaque, full glass depth | Primary / CTA actions |

```swift
// Secondary
Button("Cancel") { }
    .buttonStyle(.glass)

// Primary
Button("Save") { }
    .buttonStyle(.glassProminent)
    .tint(.blue)

// Destructive
Button("Delete") { }
    .buttonStyle(.glass)
    .tint(.red)
```

### Control Sizes

macOS Tahoe adds `.extraLarge` — use it for the single most important action in your app (e.g. "Start Recording", "Place Call").

```swift
.controlSize(.mini)       // Compact toolbars, dense UIs
.controlSize(.small)      // Sidebars, compact panels
.controlSize(.regular)    // Default
.controlSize(.large)      // Prominent actions
.controlSize(.extraLarge) // NEW — hero/launch action only
```

### Border Shapes

Control shape follows a rule: **smaller controls = rounded rect, larger = capsule**. The system does this automatically; you can override:

```swift
.buttonBorderShape(.capsule)                      // Default for large+
.buttonBorderShape(.roundedRectangle(radius: 8))  // Compact controls
.buttonBorderShape(.circle)                       // Icon-only buttons
```

### Standard Button Patterns

```swift
// Icon-only floating button
Button { } label: {
    Image(systemName: "plus")
}
.buttonStyle(.glassProminent)
.buttonBorderShape(.circle)
.controlSize(.large)
.tint(.blue)
.glassEffect(.regular.interactive())

// Text + icon toolbar button
Button("Add Item", systemImage: "plus") { }
// (in a toolbar — gets glass automatically)

// Destructive confirmation
Button(role: .destructive) {
    deleteItem()
} label: {
    Label("Delete", systemImage: "trash")
}
.buttonStyle(.glass)
```

### Custom Glass Button

For fully custom buttons outside of toolbars:

```swift
struct GlassButton: View {
    let title: String
    let icon: String
    let tintColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .glassEffect(.regular.tint(tintColor).interactive())
    }
}
```

---

## 7. Toolbars

Toolbars in macOS Tahoe receive Liquid Glass automatically when compiled with Xcode 26. The toolbar floats above window content with a translucent glass background.

### Basic Toolbar

```swift
NavigationStack {
    ContentView()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { }
                // .confirmationAction automatically gets .glassProminent styling
            }
        }
}
```

### macOS Toolbar Placements

```swift
// Leading / trailing in title bar area
ToolbarItem(placement: .navigation)           // Back/forward
ToolbarItem(placement: .primaryAction)        // Main action, leading area
ToolbarItem(placement: .secondaryAction)      // Secondary, trailing area
ToolbarItem(placement: .status)               // Center, status/title
ToolbarItem(placement: .confirmationAction)   // Confirm (Done/Save)
ToolbarItem(placement: .cancellationAction)   // Cancel
ToolbarItem(placement: .destructiveAction)    // Destructive action
```

### Grouping & Spacing

```swift
.toolbar {
    ToolbarItemGroup(placement: .primaryAction) {
        Button("Draw", systemImage: "pencil") { }
        Button("Erase", systemImage: "eraser") { }
        Button("Select", systemImage: "lasso") { }
    }

    ToolbarSpacer(.fixed, spacing: 16)      // Fixed gap
    ToolbarSpacer(.flexible)                // Push remaining items right

    ToolbarItem(placement: .confirmationAction) {
        Button("Export") { }
    }
}
```

### Toolbar with Badge

```swift
ToolbarItem {
    Button("Notifications", systemImage: "bell") { }
        .badge(unreadCount)
        .tint(unreadCount > 0 ? .red : .secondary)
}
```

### Shared Background Visibility

Hide the per-button glass background (useful when you want a custom grouped look):

```swift
ToolbarItem {
    Button("Profile", systemImage: "person.circle") { }
        .sharedBackgroundVisibility(.hidden)
}
```

### Transparent Menu Bar

macOS Tahoe introduces a fully transparent menu bar by default. If your app sets a window background, it will show through the menu bar area. Use `containerBackground(.clear, for: .navigation)` to integrate cleanly.

---

## 8. Sidebars & NavigationSplitView

The sidebar in macOS Tahoe gets a floating Liquid Glass treatment — it appears to hover over the content with ambient light reflection.

### Basic Split View

```swift
NavigationSplitView {
    List(selection: $selectedItem) {
        ForEach(sidebarItems) { item in
            Label(item.name, systemImage: item.icon)
                .tag(item)
        }
    }
    .navigationTitle("App Name")
    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
} detail: {
    if let item = selectedItem {
        DetailView(item: item)
    } else {
        ContentUnavailableView("Select an Item", systemImage: "sidebar.left")
    }
}
```

### Background Extension Effect

Extends the sidebar content behind the safe area for edge-to-edge feel:

```swift
NavigationSplitView {
    List(items) { item in
        NavigationLink(item.name, value: item)
    }
    .backgroundExtensionEffect()  // Fills sidebar to edges
} detail: {
    DetailView()
}
```

### Removing Sidebar Background for Custom Glass

```swift
List(items) { item in
    NavigationLink(item.name, value: item)
}
.scrollContentBackground(.hidden)
.background(.clear)
// The sidebar itself provides the glass — don't add another layer
```

---

## 9. Panels, Sheets & Popovers

### Sheets

macOS Tahoe sheets automatically receive an inset Liquid Glass background. Remove any custom `presentationBackground` you added in earlier OS versions:

```swift
// Present
.sheet(isPresented: $isPresented) {
    SheetContentView()
        .presentationDetents([.medium, .large])
        // Do NOT call .presentationBackground() — let system apply glass
}
```

```swift
// Sheet interior — remove background overrides
struct SheetContentView: View {
    var body: some View {
        Form {
            Section("Settings") {
                Toggle("Enable Feature", isOn: $featureEnabled)
                Slider(value: $intensity, in: 0...1)
            }
        }
        .scrollContentBackground(.hidden) // Let sheet glass show through
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
```

### Sheet Morphing Transition from Toolbar

Create a fluid zoom transition from a toolbar button into a sheet:

```swift
struct ContentView: View {
    @Namespace private var transition
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            MainContent()
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Info", systemImage: "info.circle") {
                            showInfo = true
                        }
                        .matchedTransitionSource(id: "infoButton", in: transition)
                    }
                }
                .sheet(isPresented: $showInfo) {
                    InfoSheetView()
                        .navigationTransition(.zoom(sourceID: "infoButton", in: transition))
                }
        }
    }
}
```

### Popovers

NSPopover / SwiftUI `.popover` receives glass automatically. For custom popover-style panels:

```swift
Button("Options") {
    showOptions = true
}
.popover(isPresented: $showOptions, arrowEdge: .bottom) {
    VStack(alignment: .leading, spacing: 12) {
        Button("Option A") { }
        Button("Option B") { }
        Divider()
        Button("Advanced...", role: .none) { }
    }
    .padding(16)
    .frame(minWidth: 200)
    // Popover container already has glass — don't add .glassEffect here
}
```

### Custom Floating Panel

For a custom glass overlay panel (e.g., a persistent inspector):

```swift
struct FloatingInspector: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inspector")
                .font(.headline)
                .foregroundStyle(.primary)

            Divider()

            // Panel content
            inspectorContent
        }
        .padding(20)
        .frame(width: 260)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .glassEffect() // Single glass layer for the whole panel
        }
        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
    }
}
```

---

## 10. Tab Views

`TabView` receives Liquid Glass treatment on the tab bar automatically in macOS Tahoe.

### Basic Tab View

```swift
TabView(selection: $selectedTab) {
    Tab("Home", systemImage: "house", value: Tab.home) {
        HomeView()
    }
    Tab("Library", systemImage: "books.vertical", value: Tab.library) {
        LibraryView()
    }
    Tab("Settings", systemImage: "gear", value: Tab.settings) {
        SettingsView()
    }
}
```

### Tab Bar Minimize (macOS / iPad)

```swift
TabView { /* ... */ }
    .tabBarMinimizeBehavior(.onScrollDown)  // Collapses during scroll
    // .automatic | .onScrollDown | .never
```

### Tab with Persistent Bottom Accessory (e.g. Now Playing)

```swift
TabView { /* tabs */ }
    .tabViewBottomAccessory {
        NowPlayingBar()
            .glassEffect(.regular, in: .rect(cornerRadius: .containerConcentric))
    }
```

---

## 11. Controls — Toggles, Sliders, Pickers

All standard controls receive the new design automatically when compiled with Xcode 26. Control shapes vary by size: smaller = rounded rect, larger = capsule.

### Toggle

```swift
Toggle("Enable Notifications", isOn: $notificationsEnabled)
    .toggleStyle(.switch)
// Switch automatically uses Liquid Glass material
```

### Slider with neutralValue

The slider fill can now anchor at any point, not just the minimum:

```swift
Slider(value: $playbackSpeed, in: 0.25...3.0)
    .neutralValue(1.0)  // Fill anchors at 1x — shows deviation from normal
    .tint(.blue)
```

### Picker

```swift
Picker("View", selection: $viewStyle) {
    Label("Grid", systemImage: "square.grid.2x2").tag(ViewStyle.grid)
    Label("List", systemImage: "list.bullet").tag(ViewStyle.list)
}
.pickerStyle(.segmented)
// Segmented control automatically gets glass material during interaction
```

### Tint Prominence

Controls now support varying visual weight:

```swift
Button("Primary Action") { }
    .buttonStyle(.glassProminent)
    .tint(.blue)
    // High prominence — full glass depth

Button("Secondary") { }
    .buttonStyle(.glass)
    // Standard prominence
```

---

## 12. Menus

Menus in macOS Tahoe have a refreshed look with a strong emphasis on icons. Each section presents icons in a single scannable column.

### Menu with Icons (required pattern)

```swift
Menu {
    Section {
        Button("New Document", systemImage: "doc.badge.plus") { }
        Button("Open...", systemImage: "folder") { }
        Button("Import...", systemImage: "square.and.arrow.down") { }
    }
    Section {
        Button("Share", systemImage: "square.and.arrow.up") { }
        Button("Duplicate", systemImage: "plus.square.on.square") { }
    }
    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) { }
} label: {
    Image(systemName: "ellipsis.circle")
}
// Every menu item should have a systemImage in macOS Tahoe
```

### Context Menu

```swift
someView
    .contextMenu {
        Button("Copy", systemImage: "doc.on.doc") { }
        Button("Paste", systemImage: "clipboard") { }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { }
    }
```

---

## 13. Typography & Color

### System Fonts — Use `.system` or semantic styles

Do **not** embed custom fonts just for the sake of it. The system SF Pro family adapts automatically to Dynamic Type and accessibility settings.

```swift
// Semantic styles (preferred)
Text("Title").font(.largeTitle)     // 34pt bold
Text("Heading").font(.title)        // 28pt bold
Text("Subheading").font(.title2)    // 22pt
Text("Section").font(.title3)       // 20pt
Text("Body").font(.body)            // 17pt
Text("Label").font(.callout)        // 16pt
Text("Caption").font(.caption)      // 12pt

// With weight
Text("Emphasis").font(.body).fontWeight(.semibold)

// Monospace for code/numbers
Text("42.0").font(.system(.body, design: .monospaced))
```

### Color — Semantic System Colors

Always use semantic colors so the UI responds correctly to dark mode, accessibility, and tinting:

```swift
// ✅ Correct — adaptive
Color.primary          // Primary text
Color.secondary        // Secondary text
Color.tertiary         // Tertiary/placeholder
Color.accentColor      // App accent (defined in Assets.xcassets)

// Background layers
Color(.windowBackgroundColor)   // Window background (AppKit)
Color(.controlBackgroundColor)  // Control surfaces
Color(.separatorColor)          // Dividers

// ❌ Avoid — not adaptive
Color(red: 0.1, green: 0.1, blue: 0.1)
```

### Text Legibility on Glass

Text over glass automatically receives vibrant treatment. To ensure legibility:

```swift
Text("Over Glass")
    .foregroundStyle(.primary)  // Let system handle vibrance
    .fontWeight(.semibold)      // Heavier weight reads better on glass
    .padding()
    .glassEffect()
```

---

## 14. Spacing & Layout Tokens

macOS Tahoe does not publish hardcoded spacing tokens, but these values are consistent with Apple's HIG and observed system UI:

| Token | Value | Use For |
|---|---|---|
| `xs` | 4 pt | Icon-to-label gap, hairline separation |
| `sm` | 8 pt | Internal component padding |
| `md` | 12 pt | Default inter-element spacing |
| `lg` | 16 pt | Section padding, card inner padding |
| `xl` | 20 pt | Panel/sheet outer padding |
| `2xl` | 24 pt | Section-to-section gap |
| `3xl` | 32 pt | Top/bottom panel margins |

```swift
// Define as constants
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}
```

### Touch Target Minimums

```swift
// Minimum tappable area is 44×44 pt
.frame(minWidth: 44, minHeight: 44)
// Or use contentShape to expand hit area
.contentShape(Rectangle())
```

---

## 15. Morphing Animations with glassEffectID

Create fluid glass morphing between states using `@Namespace` and `glassEffectID`.

### Requirements

1. All elements must be inside the same `GlassEffectContainer`
2. Each element needs `.glassEffectID(_:in:)` with a shared namespace
3. State changes wrapped in an animation

### Pattern: Collapsing Action Menu

```swift
struct CollapsibleActionBar: View {
    @State private var isExpanded = false
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 28) {
            HStack(spacing: 16) {
                if isExpanded {
                    Button("Crop", systemImage: "crop") { }
                        .glassEffect(.regular.interactive())
                        .glassEffectID("crop", in: namespace)

                    Button("Rotate", systemImage: "rotate.right") { }
                        .glassEffect(.regular.interactive())
                        .glassEffectID("rotate", in: namespace)

                    Button("Filter", systemImage: "camera.filters") { }
                        .glassEffect(.regular.interactive())
                        .glassEffectID("filter", in: namespace)
                }

                Button(isExpanded ? "Done" : "Edit",
                       systemImage: isExpanded ? "checkmark" : "slider.horizontal.3") {
                    withAnimation(.bouncy(duration: 0.4)) {
                        isExpanded.toggle()
                    }
                }
                .glassEffect(.regular.tint(isExpanded ? .green : .primary).interactive())
                .glassEffectID("toggle", in: namespace)
            }
        }
        .padding()
    }
}
```

### Pattern: Glass Union (Fused elements)

Make multiple glass elements appear as a single fused shape:

```swift
@Namespace var ns

VStack(spacing: 0) {
    Button { zoomIn() } label: {
        Image(systemName: "plus").frame(width: 44, height: 44)
    }
    .glassEffect()
    .glassEffectUnion(id: "zoomControl", namespace: ns)

    Divider().frame(width: 44)

    Button { zoomOut() } label: {
        Image(systemName: "minus").frame(width: 44, height: 44)
    }
    .glassEffect()
    .glassEffectUnion(id: "zoomControl", namespace: ns)
}
```

---

## 16. Accessibility

The system handles Liquid Glass accessibility automatically. Do not override unless absolutely necessary.

### Automatic Adaptations (No Code Required)

- **Reduce Transparency**: Increases frosting, reduces see-through
- **Increase Contrast**: Stark borders and colors
- **Reduce Motion**: Disables elastic/bounce animations, morphing transitions
- **Liquid Glass Tint Mode** (macOS 26.1+): User-controlled opacity increase

### Manual Override If Needed

```swift
@Environment(\.accessibilityReduceTransparency) var reduceTransparency
@Environment(\.accessibilityReduceMotion) var reduceMotion

var body: some View {
    MyFloatingControl()
        .glassEffect(reduceTransparency ? .identity : .regular)
        .animation(reduceMotion ? nil : .bouncy, value: state)
}
```

### Disable Liquid Glass for Entire App (User Preference)

Terminal command (users can run this):
```bash
defaults write -g com.apple.SwiftUI.DisableSolarium -bool YES
```

Per-app disable:
```bash
defaults write com.yourcompany.YourApp com.apple.SwiftUI.DisableSolarium -bool YES
```

---

## 17. What You Get for Free (Zero Code)

Recompile with Xcode 26 targeting macOS 26 and these elements automatically adopt Liquid Glass:

**Structure:**
- Toolbar, title bar, menu bar
- Sidebar (NavigationSplitView)
- Window chrome (traffic lights, resize handle)
- Dock (system level)

**Navigation:**
- NavigationStack / NavigationSplitView bars
- Tab bars (TabView)

**Presentations:**
- Sheets with inset glass background
- NSPopover / SwiftUI `.popover`
- Alerts and confirmation dialogs

**Controls:**
- Toggle (switch style)
- Slider (including fill and thumb)
- Segmented Picker (during interaction)
- Buttons in toolbars

**System Chrome:**
- Transparent menu bar
- Search bars (`.searchable`)
- Scroll edge fade effects

---

## 18. Critical Anti-Patterns

### Never apply glass to content

```swift
// ❌ WRONG
List {
    ForEach(items) { item in
        Row(item).glassEffect()
    }
}

// ✅ CORRECT
ZStack {
    List { ForEach(items) { Row($0) } }
    floatingControls.glassEffect()
}
```

### Never stack glass on glass without a container

```swift
// ❌ WRONG — each samples independently, visual inconsistency
HStack {
    Button("A") { }.glassEffect()
    Button("B") { }.glassEffect()
}

// ✅ CORRECT
GlassEffectContainer {
    HStack {
        Button("A") { }.glassEffect()
        Button("B") { }.glassEffect()
    }
}
```

### Never use glass full-bleed on backgrounds

```swift
// ❌ WRONG — glass is not a window background
VStack { content }
    .background { Color.clear.glassEffect(in: .rect) }

// ✅ CORRECT — use system materials for backgrounds
VStack { content }
    .background(.regularMaterial)
```

### Never add glassEffect inside the body of a scrollable content list

```swift
// ❌ WRONG — glass inside scroll = broken lensing
ScrollView {
    VStack {
        ForEach(items) { item in
            CardView(item)
                .glassEffect() // Don't do this
        }
    }
}
```

### Never apply redundant background to a sheet

```swift
// ❌ WRONG — removes automatic glass
.presentationBackground(Color.white)

// ✅ CORRECT — omit; system applies glass
.sheet(isPresented: $show) { SheetContent() }
```

---

## 19. Compatibility & Deployment Targets

`.glassEffect()` requires **macOS 26 (Tahoe) / iOS 26+**. Use availability checks for backward compatibility:

```swift
struct GlassOrFallbackButton: View {
    var body: some View {
        Button("Action") { }
            .modifier(GlassModifier())
    }
}

struct GlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular.interactive())
        } else {
            // Fallback for macOS 14/15
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        }
    }
}
```

### Conditional Glass Helper

```swift
extension View {
    func conditionalGlass(
        _ glass: Glass = .regular,
        in shape: some Shape = Capsule()
    ) -> some View {
        Group {
            if #available(macOS 26, iOS 26, *) {
                self.glassEffect(glass, in: shape)
            } else {
                self.background(.regularMaterial, in: shape)
            }
        }
    }
}
```

---

## 20. Full App Skeleton

A complete macOS Tahoe app demonstrating all major patterns:

```swift
import SwiftUI

@main
struct TahoeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)  // Custom title bar if needed
        .commands {
            AppCommands()
        }
    }
}

// MARK: — Root Content View

struct ContentView: View {
    @State private var selectedItem: SidebarItem? = .home
    @State private var showInspector = false
    @Namespace private var glassNamespace

    var body: some View {
        NavigationSplitView {
            // Sidebar — gets floating glass automatically
            SidebarView(selection: $selectedItem)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            DetailView(
                item: selectedItem,
                showInspector: $showInspector,
                namespace: glassNamespace
            )
        }
    }
}

// MARK: — Sidebar

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(SidebarItem.allCases, selection: $selection) { item in
            Label(item.title, systemImage: item.icon)
                .tag(item)
        }
        .navigationTitle("MyApp")
        .backgroundExtensionEffect()
    }
}

// MARK: — Detail View

struct DetailView: View {
    let item: SidebarItem?
    @Binding var showInspector: Bool
    var namespace: Namespace.ID

    @State private var searchText = ""
    @State private var showSheet = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Content layer — no glass here
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(filteredItems) { row in
                        ItemRow(row)
                    }
                }
                .padding()
            }
            .searchable(text: $searchText)
            .navigationTitle(item?.title ?? "Select Item")
            .toolbar {
                // Toolbar gets glass automatically
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("View Options", systemImage: "square.grid.2x2") { }
                    Button("Inspector", systemImage: "sidebar.trailing") {
                        showInspector.toggle()
                    }
                }
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .confirmationAction) {
                    Button("New Item", systemImage: "plus") {
                        showSheet = true
                    }
                    .matchedTransitionSource(id: "newItemButton", in: namespace)
                }
            }

            // Floating glass controls — live above content layer
            GlassEffectContainer(spacing: 24) {
                VStack(spacing: 12) {
                    Button { } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 40, height: 40)
                    }
                    .glassEffect(.regular.interactive())

                    Button { } label: {
                        Image(systemName: "arrow.down")
                            .frame(width: 40, height: 40)
                    }
                    .glassEffect(.regular.interactive())
                }
                .padding()
            }
        }
        .sheet(isPresented: $showSheet) {
            NewItemSheet()
                .navigationTransition(.zoom(sourceID: "newItemButton", in: namespace))
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
        }
    }

    var filteredItems: [Item] { /* filter logic */ [] }
}

// MARK: — Sheet

struct NewItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var itemName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $itemName)
                    // More fields...
                }
            }
            .scrollContentBackground(.hidden) // Let sheet glass show
            .navigationTitle("New Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { /* save */ dismiss() }
                        .disabled(itemName.isEmpty)
                    // .confirmationAction auto-applies .glassProminent style
                }
            }
        }
    }
}

// MARK: — Inspector Panel

struct InspectorView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inspector")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal)
                .padding(.top)

            Divider()

            // Inspector content
            Form {
                Section("Properties") {
                    LabeledContent("Type", value: "Document")
                    LabeledContent("Size", value: "42 KB")
                    LabeledContent("Modified", value: "Today")
                }
            }
            .scrollContentBackground(.hidden)

            Spacer()
        }
        .inspectorColumnWidth(min: 200, ideal: 250, max: 320)
    }
}

// MARK: — Commands

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import...", systemImage: "square.and.arrow.down") { }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

// MARK: — Supporting Types

enum SidebarItem: String, CaseIterable, Identifiable {
    case home, library, settings

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .settings: "gear"
        }
    }
}

struct Item: Identifiable {
    let id = UUID()
    var name: String
}
```

---

## Quick Reference Card

```swift
// ─── The 5 lines you'll write most ───────────────────────────────────

// 1. Floating button
Button("Action") { }.glassEffect(.regular.interactive())

// 2. Primary CTA
Button("Save") { }.buttonStyle(.glassProminent).tint(.blue)

// 3. Multiple glass buttons together
GlassEffectContainer { HStack { btn1.glassEffect(); btn2.glassEffect() } }

// 4. Custom glass panel
view.background { RoundedRectangle(cornerRadius: 16, style: .continuous).glassEffect() }

// 5. Conditional glass (backward compatible)
if #available(macOS 26, *) { view.glassEffect() } else { view.background(.regularMaterial) }
```

---

## Key WWDC 2025 Sessions

- **Session 219**: Meet Liquid Glass — core concepts and design philosophy
- **Session 323**: Build a SwiftUI app with the new design — practical implementation
- **Session 310**: Build an AppKit app with the new design — AppKit APIs, NSGlassContainerView

---

*Last updated: March 2026. Targets macOS Tahoe 26 / Xcode 26 / Swift 6.*
