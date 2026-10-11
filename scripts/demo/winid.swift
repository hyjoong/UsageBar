import CoreGraphics
import Foundation
// usage: winid [ownerPID]  -> first UsageBar window (normal or floating level) wider than 300pt
let wantedPID = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let width = (w[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Int ?? 0
    if owner == "UsageBar", layer == 0 || layer == 3, width >= 300, wantedPID == nil || pid == wantedPID,
       let id = w[kCGWindowNumber as String] as? Int { print(id); break }
}
