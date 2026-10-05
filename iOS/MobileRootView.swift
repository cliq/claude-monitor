// iOS/MobileRootView.swift
import SwiftUI

enum MobileTab: String, CaseIterable, Identifiable {
    case sessions, usage

    var id: Self { self }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .usage: "Usage"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions: "square.grid.2x2.fill"
        case .usage: "gauge.with.dots.needle.50percent"
        }
    }
}

/// The two tabs as pages of a horizontal paging scroll view, so they can be
/// swiped between, over a custom tab bar whose highlight follows the swipe.
/// A system `TabView` can't page, and a `.page`-style one has no tab bar.
struct MobileRootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessions: SessionsStore
    @ObservedObject var browser: BridgeBrowser
    @AppStorage("selectedTab") private var selectedTab = MobileTab.sessions
    /// The page the pager rests on; nil only transiently around layout.
    @State private var position: MobileTab?
    /// Fractional page index while scrolling (iOS 18+); nil falls back to
    /// `selectedTab`, animated.
    @State private var scrollProgress: CGFloat?
    @State private var showingPicker = false

    init(store: UsageStore, sessions: SessionsStore, browser: BridgeBrowser) {
        self.store = store
        self.sessions = sessions
        self.browser = browser
        // Start on the persisted tab without sliding to it.
        let stored = UserDefaults.standard.string(forKey: "selectedTab").flatMap(MobileTab.init(rawValue:))
        _position = State(initialValue: stored ?? .sessions)
    }

    var body: some View {
        NavigationStack {
            pager
                .background(UsagePalette.bg)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MobileTabBar(selection: selectedTab,
                                 progress: scrollProgress ?? CGFloat(selectedTab.index),
                                 select: select)
                }
                .navigationTitle(selectedTab.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(UsagePalette.statusBg, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar { toolbar }
        }
        .sheet(isPresented: $showingPicker) {
            ServerPickerView(store: store, browser: browser)
        }
        .onAppear {
            if store.endpoint == nil { showingPicker = true }
        }
        .onChange(of: position) { _, page in
            if let page, page != selectedTab { selectedTab = page }
        }
        // Outside the stack so the picker sheet inherits it too.
        .tint(UsagePalette.name)
    }

    private var pager: some View {
        // Paging steps by the scroll view's full width, so it spans the
        // horizontal safe area (landscape notch) and each page puts the
        // insets back; otherwise pages are narrower than a step and drift.
        GeometryReader { geo in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(MobileTab.allCases) { tab in
                        page(tab)
                            .safeAreaPadding(.leading, geo.safeAreaInsets.leading)
                            .safeAreaPadding(.trailing, geo.safeAreaInsets.trailing)
                            .containerRelativeFrame(.horizontal)
                            .id(tab)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .ignoresSafeArea(.container, edges: .horizontal)
            .modifier(PageProgressTracker(progress: $scrollProgress))
        }
    }

    @ViewBuilder
    private func page(_ tab: MobileTab) -> some View {
        switch tab {
        case .sessions:
            MobileSessionsView(sessions: sessions, store: store, chooseMac: chooseMac)
        case .usage:
            MobileUsageView(store: store, chooseMac: chooseMac)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch selectedTab {
        case .sessions:
            ToolbarItem(placement: .topBarLeading) {
                SessionPaletteMenu()
            }
        case .usage:
            ToolbarItem(placement: .topBarLeading) {
                UsageLayoutToggle()
            }
            ToolbarItem(placement: .topBarTrailing) {
                WidgetAccountMenu(store: store)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: chooseMac) {
                Image(systemName: "desktopcomputer")
            }
            .accessibilityLabel("Choose Mac")
        }
    }

    private func select(_ tab: MobileTab) {
        withAnimation(.snappy) { position = tab }
    }

    private func chooseMac() {
        showingPicker = true
    }
}

/// Feeds the pager's fractional page index into `progress` on iOS 18+, where
/// scroll geometry is observable; earlier systems leave it nil.
private struct PageProgressTracker: ViewModifier {
    @Binding var progress: CGFloat?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                let width = geometry.containerSize.width
                guard width > 0 else { return 0 }
                return (geometry.contentOffset.x + geometry.contentInsets.leading) / width
            } action: { _, value in
                progress = value
            }
        } else {
            content
        }
    }
}

/// Bottom tab bar with a pill that slides between the tabs as the pager
/// scrolls; `progress` is the fractional page index.
struct MobileTabBar: View {
    let selection: MobileTab
    let progress: CGFloat
    let select: (MobileTab) -> Void

    private let tabs = MobileTab.allCases

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    select(tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(UsagePalette.name.opacity(0.35 + 0.65 * closeness(to: tab)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geo in
                let width = geo.size.width / CGFloat(tabs.count)
                Capsule()
                    .fill(UsagePalette.name.opacity(0.14))
                    .frame(width: width - 16)
                    .offset(x: width * clampedProgress + 8)
            }
        }
        .animation(.snappy, value: selection)
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            UsagePalette.statusBg
                .overlay(alignment: .top) { Rectangle().fill(UsagePalette.line).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private var clampedProgress: CGFloat {
        min(max(progress, 0), CGFloat(tabs.count - 1))
    }

    /// 1 when the pager rests on `tab`, fading to 0 one page away.
    private func closeness(to tab: MobileTab) -> CGFloat {
        max(0, 1 - abs(clampedProgress - CGFloat(tab.index)))
    }
}
