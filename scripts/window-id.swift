// Prints the CGWindowID of a window of a process: swift scripts/window-id.swift <pid> [title-substring]
// Without a title, the largest on-screen window of the process. Prints nothing (exit 1) when there is none.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else { FileHandle.standardError.write(Data("usage: window-id.swift <pid> [title]\n".utf8)); exit(2) }
let title = args.count > 2 ? args[2] : nil
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
var best: (id: Int, area: Double)?
for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
    let name = window[kCGWindowName as String] as? String ?? ""
    if let title, !name.contains(title) { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    if area > 0, area > (best?.area ?? 0) { best = (window[kCGWindowNumber as String] as? Int ?? 0, area) }
}
if let best { print(best.id) } else { exit(1) }
