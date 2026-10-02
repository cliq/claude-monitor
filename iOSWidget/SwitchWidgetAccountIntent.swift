import AppIntents
import SwiftUI
import WidgetKit

/// Moves the widget to the previous/next account the app lists. Runs in the
/// widget extension; WidgetKit reloads the timeline once `perform()` returns,
/// which fetches the new pick from the Mac — so no `reloadTimelines` here.
///
/// It steps through `WidgetAccountStore.cycleIDs()`, the cache of every
/// account the app lists (falling back to the `/usage` cache before the app
/// has written it), so taps stay instant and work away from the Mac. It steps
/// from the account on screen (`current`), not the stored pick: with no pick
/// the widget shows the Mac's selection, whose first account need not be the
/// first one the app lists.
struct SwitchWidgetAccountIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Widget Account"
    static var isDiscoverable = false

    @Parameter(title: "Step")
    var step: Int

    @Parameter(title: "Current Account")
    var current: String

    init() {}

    init(step: Int, current: String) {
        self.step = step
        self.current = current
    }

    func perform() async throws -> some IntentResult {
        let ids = WidgetAccountStore.cycleIDs()
        if let next = WidgetAccountStore.next(from: current, in: ids, step: step) {
            WidgetAccountStore.save(next)
        }
        return .result()
    }
}

/// One of the widget's two account buttons: a right-aligned chevron (up =
/// previous account, down = next, in the Mac's order, wrapping around) with
/// the name of the account a tap will show beside it.
struct AccountSwitcherButton: View {
    let direction: AccountSwitchDirection
    /// `AccountUsage.id` of the account the widget shows.
    let currentID: String
    /// What the buttons step through (`UsageEntry.switchableAccounts`).
    let accounts: [AccountUsage]

    private var target: AccountUsage? {
        let id = WidgetAccountStore.next(from: currentID, in: accounts.map(\.id), step: direction.step)
        return accounts.first { $0.id == id }
    }

    var body: some View {
        Button(intent: SwitchWidgetAccountIntent(step: direction.step, current: currentID)) {
            HStack(spacing: 4) {
                if let target {
                    Text(target.name.uppercased())
                        .font(.system(size: 7, weight: .medium))
                        .kerning(0.8)
                        .foregroundStyle(UsagePalette.muted)
                        .lineLimit(1)
                    Text(target.provider.displayName.uppercased())
                        .font(.system(size: 6, weight: .medium))
                        .kerning(0.6)
                        .foregroundStyle(UsagePalette.idle)
                        .lineLimit(1)
                }
                Image(systemName: direction == .previous ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UsagePalette.muted)
            }
            .padding(.vertical, 2)
            .padding(.leading, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction == .previous ? "Previous account" : "Next account")
        .accessibilityValue(target?.name ?? "")
    }
}
