//
//  HRZonesMacApp.swift
//  HRZonesMac
//
//  macOS version: instead of HealthKit (which doesn't sync Health data to
//  the Mac), this app parses the Health export you create on the iPhone:
//  Health app → tap your profile picture → Export All Health Data →
//  AirDrop/save the export.zip to the Mac, then open it here.
//
//  Requires: macOS 14+, Xcode target "macOS App" (SwiftUI).
//  No special capabilities needed. If App Sandbox is enabled (default),
//  make sure "User Selected File" is set to Read Only under
//  Signing & Capabilities → App Sandbox → File Access.
//

import SwiftUI

@main
struct HRZonesMacApp: App {
    @StateObject private var dataStore = HealthExportStore()
    @StateObject private var zoneStore = ZoneStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataStore)
                .environmentObject(zoneStore)
                .frame(minWidth: 700, minHeight: 1095)
        }
        .windowResizability(.contentSize)
    }
}
