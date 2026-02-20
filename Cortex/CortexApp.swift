//
//  CortexApp.swift
//  Cortex
//
//  Created by Adam Carlton on 2/19/26.
//

import SwiftUI

@main
struct CortexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appDelegate.captureService)
        }
    }
}
