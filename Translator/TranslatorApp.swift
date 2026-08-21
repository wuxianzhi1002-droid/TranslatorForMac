//
//  TranslatorApp.swift
//  Translator
//
//  Created by Administrator on 2026/8/4.
//

import SwiftUI

@main
@MainActor
struct TranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
