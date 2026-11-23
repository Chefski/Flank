//
//  FlankApp.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI

@main
struct FlankApp: App {
    init() {
        Analytics.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
