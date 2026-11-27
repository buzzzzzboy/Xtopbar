import Foundation
import CoreGraphics

// 工作列小工具的纯逻辑回归测试：`./scripts/test-widgets.sh`
var failures = 0
func check(_ ok: Bool, _ name: String) {
    if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func w(_ kind: TaskbarWidget.Kind, _ slot: TaskbarWidgetSlot) -> TaskbarWidget {
    TaskbarWidget(kind: kind, slot: slot)
}

// arrangeKeepsOrderWithinSlot
do {
    let a = w(.nowPlaying, .afterBar), b = w(.systemStats, .afterBar), c = w(.folder(UUID()), .afterBar)
    let r = WidgetArrangement.arrange([a, b, c], isVisible: { _ in true }, hasTabs: true)
    check(r.afterBar.map(\.id) == [a.id, b.id, c.id], "arrangeKeepsOrderWithinSlot")
}

// invisibleWidgetsDropped
do {
    let a = w(.nowPlaying, .beforeStart), b = w(.systemStats, .beforeStart)
    let r = WidgetArrangement.arrange([a, b], isVisible: { $0.id != a.id }, hasTabs: true)
    let all = r.beforeStart + r.afterStart + r.beforeBar + r.barLeading + r.barTrailing + r.afterBar
    check(!all.contains { $0.id == a.id } && r.beforeStart.map(\.id) == [b.id], "invisibleWidgetsDropped")
}

// noTabsMovesInnerSlotsOutside
do {
    let l = w(.nowPlaying, .barLeading), t = w(.systemStats, .barTrailing)
    let b = w(.folder(UUID()), .beforeBar), rr = w(.folder(UUID()), .afterBar)
    let r = WidgetArrangement.arrange([l, t, b, rr], isVisible: { _ in true }, hasTabs: false)
    check(r.beforeBar.map(\.id) == [b.id, l.id] && r.afterBar.map(\.id) == [t.id, rr.id]
          && r.barLeading.isEmpty && r.barTrailing.isEmpty, "noTabsMovesInnerSlotsOutside")
}

// arrangementIsEmpty
do {
    check(WidgetArrangement.arrange([], isVisible: { _ in true }, hasTabs: true).isEmpty, "arrangementIsEmpty")
    check(!WidgetArrangement.arrange([w(.nowPlaying, .afterBar)], isVisible: { _ in true }, hasTabs: true).isEmpty,
          "arrangementNotEmpty")
}

// nowPlayingWidthIgnoresTitle
do {
    let a = TaskbarWidgetMetrics.width(.nowPlaying, iconOnly: false, barBaseHeight: 42, folderName: nil)
    let b = TaskbarWidgetMetrics.width(.nowPlaying, iconOnly: false, barBaseHeight: 42, folderName: nil)
    check(a == b && a >= 42 / 2 * 2 + 140, "nowPlayingWidthIgnoresTitle")
}

// iconOnlyIsNarrower
do {
    let kinds: [TaskbarWidget.Kind] = [.nowPlaying, .systemStats, .folder(UUID())]
    let ok = kinds.allSatisfy {
        TaskbarWidgetMetrics.width($0, iconOnly: true, barBaseHeight: 58, folderName: "工具")
            < TaskbarWidgetMetrics.width($0, iconOnly: false, barBaseHeight: 58, folderName: "工具")
    }
    check(ok, "iconOnlyIsNarrower")
}

// canAddRejectsDuplicates
do {
    let x = UUID(), y = UUID()
    let list = [w(.nowPlaying, .afterBar), w(.folder(x), .afterBar)]
    check(!TaskbarWidgetList.canAdd(.nowPlaying, to: list)
          && TaskbarWidgetList.canAdd(.systemStats, to: list)
          && !TaskbarWidgetList.canAdd(.folder(x), to: list)
          && TaskbarWidgetList.canAdd(.folder(y), to: list), "canAddRejectsDuplicates")
}

// movingAppendsToTargetSlot
do {
    let a = w(.nowPlaying, .beforeStart), b = w(.systemStats, .afterBar), c = w(.folder(UUID()), .afterBar)
    let r = TaskbarWidgetList.moving(a.id, to: .afterBar, in: [a, b, c])
    let after = r.filter { $0.slot == .afterBar }.map(\.id)
    check(after == [b.id, c.id, a.id], "movingAppendsToTargetSlot")
}

// shiftingStaysInSlot
do {
    let a = w(.nowPlaying, .afterBar), other = w(.systemStats, .beforeStart), b = w(.folder(UUID()), .afterBar)
    let list = [a, other, b]
    let down = TaskbarWidgetList.shifting(a.id, by: 1, in: list)
    check(down.filter { $0.slot == .afterBar }.map(\.id) == [b.id, a.id], "shiftingSwapsSameSlotNeighbour")
    check(TaskbarWidgetList.shifting(a.id, by: -1, in: list) == list, "shiftingFirstUpIsNoop")
    check(TaskbarWidgetList.shifting(other.id, by: 1, in: list) == list, "shiftingLoneInSlotIsNoop")
}

// removingFolderDropsWidget
do {
    let x = UUID(), y = UUID()
    let fx = w(.folder(x), .afterBar), fy = w(.folder(y), .afterBar), np = w(.nowPlaying, .afterBar)
    let r = TaskbarWidgetList.pruned([fx, fy, np], existingFolders: [y])
    check(r.map(\.id) == [fy.id, np.id], "removingFolderDropsWidget")
}

// codableRoundTrip
do {
    let list = [w(.nowPlaying, .beforeStart), w(.systemStats, .barTrailing), w(.folder(UUID()), .afterBar)]
    let data = try! JSONEncoder().encode(list)
    let back = try! JSONDecoder().decode([TaskbarWidget].self, from: data)
    check(back == list, "codableRoundTrip")
}

// 小工具的保留 id
do {
    let a = w(.nowPlaying, .afterBar)
    check(a.hitID == "__widget__\(a.id.uuidString)" && a.prevHitID == a.hitID + "__prev"
          && a.nextHitID == a.hitID + "__next", "hitIDs")
}

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASS")
