#!/usr/bin/env swift
// Prints the CGWindowID of the frontmost on-screen window owned by the given app name.
// Usage: swift script/windowid.swift Vivarium

import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: windowid.swift <app-name>\n".utf8))
    exit(2)
}
let appName = CommandLine.arguments[1]

guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

for window in info {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner == appName,
          let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 200 else { continue }
    print(number)
    exit(0)
}
exit(1)
