import Foundation
import FamilyControls

/// An app change waiting for the keyholder. Holds only what the change opens
/// up, so stricter edits made in the meantime are never undone by an approval.
struct PendingAppChange: Codable {
    let requestID: UUID
    let createdAt: Date
    let blockID: String
    let mode: BlockMode
    let opened: FamilyActivitySelection
}

/// Splits an edit to the blocked apps by the rule: anything stricter applies
/// now, anything that opens an app up waits for the keyholder.
///
/// In "selected" mode the selection lists what is blocked, so adding is
/// stricter. In "everything except" mode it lists what stays open, so
/// removing is stricter.
struct AppChangePlan {
    let mode: BlockMode
    /// The selection to apply now: the current one plus every stricter part of the edit.
    let immediate: FamilyActivitySelection
    /// What the edit opens up. Applied only once the keyholder approves.
    let opened: FamilyActivitySelection
    /// What the edit blocks right away.
    let closed: FamilyActivitySelection

    init(mode: BlockMode, current: FamilyActivitySelection, draft: FamilyActivitySelection) {
        self.mode = mode
        var immediate = current
        var opened = AppChangePlan.empty(for: mode)
        var closed = AppChangePlan.empty(for: mode)

        switch mode {
        case .selected:
            immediate.applicationTokens = current.applicationTokens.union(draft.applicationTokens)
            immediate.categoryTokens = current.categoryTokens.union(draft.categoryTokens)
            immediate.webDomainTokens = current.webDomainTokens.union(draft.webDomainTokens)
            opened.applicationTokens = current.applicationTokens.subtracting(draft.applicationTokens)
            opened.categoryTokens = current.categoryTokens.subtracting(draft.categoryTokens)
            opened.webDomainTokens = current.webDomainTokens.subtracting(draft.webDomainTokens)
            closed.applicationTokens = draft.applicationTokens.subtracting(current.applicationTokens)
            closed.categoryTokens = draft.categoryTokens.subtracting(current.categoryTokens)
            closed.webDomainTokens = draft.webDomainTokens.subtracting(current.webDomainTokens)
        case .allExcept:
            immediate.applicationTokens = current.applicationTokens.intersection(draft.applicationTokens)
            immediate.categoryTokens = current.categoryTokens.intersection(draft.categoryTokens)
            immediate.webDomainTokens = current.webDomainTokens.intersection(draft.webDomainTokens)
            opened.applicationTokens = draft.applicationTokens.subtracting(current.applicationTokens)
            opened.categoryTokens = draft.categoryTokens.subtracting(current.categoryTokens)
            opened.webDomainTokens = draft.webDomainTokens.subtracting(current.webDomainTokens)
            closed.applicationTokens = current.applicationTokens.subtracting(draft.applicationTokens)
            closed.categoryTokens = current.categoryTokens.subtracting(draft.categoryTokens)
            closed.webDomainTokens = current.webDomainTokens.subtracting(draft.webDomainTokens)
        }

        self.immediate = immediate
        self.opened = opened
        self.closed = closed
    }

    var opensAnything: Bool { !AppChangePlan.isEmpty(opened) }
    var tightensAnything: Bool { !AppChangePlan.isEmpty(closed) }

    /// The selection once the keyholder approves.
    var proposed: FamilyActivitySelection { AppChangePlan.applying(opened, to: immediate, mode: mode) }

    // MARK: Helpers

    static func empty(for mode: BlockMode) -> FamilyActivitySelection {
        FamilyActivitySelection(includeEntireCategory: mode == .allExcept)
    }

    /// Adds an approved opening to a selection.
    static func applying(_ opened: FamilyActivitySelection, to current: FamilyActivitySelection,
                         mode: BlockMode) -> FamilyActivitySelection {
        var result = current
        switch mode {
        case .selected:
            result.applicationTokens.subtract(opened.applicationTokens)
            result.categoryTokens.subtract(opened.categoryTokens)
            result.webDomainTokens.subtract(opened.webDomainTokens)
        case .allExcept:
            result.applicationTokens.formUnion(opened.applicationTokens)
            result.categoryTokens.formUnion(opened.categoryTokens)
            result.webDomainTokens.formUnion(opened.webDomainTokens)
        }
        return result
    }

    static func isEmpty(_ s: FamilyActivitySelection) -> Bool {
        s.applicationTokens.isEmpty && s.categoryTokens.isEmpty && s.webDomainTokens.isEmpty
    }

    static func same(_ a: FamilyActivitySelection, _ b: FamilyActivitySelection) -> Bool {
        a.applicationTokens == b.applicationTokens
            && a.categoryTokens == b.categoryTokens
            && a.webDomainTokens == b.webDomainTokens
    }

    /// Apps (websites count as apps) and categories in a selection.
    static func counts(_ s: FamilyActivitySelection) -> (apps: Int, categories: Int) {
        (s.applicationTokens.count + s.webDomainTokens.count, s.categoryTokens.count)
    }

    /// What the server records as the block's size for a selection in a mode.
    static func blockSize(_ s: FamilyActivitySelection, mode: BlockMode)
        -> (appCount: Int, categoryCount: Int, allowedCount: Int) {
        switch mode {
        case .selected: return (s.applicationTokens.count, s.categoryTokens.count, 0)
        case .allExcept: return (0, 0, s.applicationTokens.count)
        }
    }
}
