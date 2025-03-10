//
//  SettingsView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI
import BetterSafariView

struct SettingsView: View {
    @State private var showTermsOfService = false
    @State private var showPrivacyPolicy = false
    @State private var showAboutView = false
    
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    @AppStorage("defaultTab") private var defaultTab = "Upcoming"
    @AppStorage("defaultRegion") private var defaultRegion = "na"
    
    private let regionNames = [
        "na": "North America",
        "eu": "Europe",
        "br": "Brazil",
        "ap": "Asia-Pacific",
        "la-s": "LA South",
        "kr": "Korea",
        "cn": "China",
        "gc": "Game Changers",
        "la-n": "LA North",
        "mn": "Mena"
    ]
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Info"), footer: Text("General app information")) {
                    Button(action: {
                        showAboutView = true
                    }) {
                        Label("About", systemImage: "info.circle")
                    }
                    .sheet(isPresented: $showAboutView, content: { AboutView() })
                    Button(action: {
                        showTermsOfService = true
                    }) {
                        Label("Terms of service", systemImage: "doc.text")
                    }
                    .sheet(isPresented: $showTermsOfService) {
                        SafariView(
                            url: URL(string: "https://www.chefski.dev/flank-terms-conditions")!,
                            configuration: SafariView.Configuration(
                                entersReaderIfAvailable: false,
                                barCollapsingEnabled: true
                            )
                        )
                        .preferredBarAccentColor(.clear)
                        .preferredControlAccentColor(.accentColor)
                        .dismissButtonStyle(.done)
                        .ignoresSafeArea()
                    }
                    Button(action: {
                        showPrivacyPolicy = true
                    }) {
                        Label("Privacy Policy", systemImage: "shield")
                    }
                    .sheet(isPresented: $showPrivacyPolicy) {
                        SafariView(
                            url: URL(string: "https://www.chefski.dev/flank-privacy-policy")!,
                            configuration: SafariView.Configuration(
                                entersReaderIfAvailable: false,
                                barCollapsingEnabled: true
                            )
                        )
                        .preferredBarAccentColor(.clear)
                        .preferredControlAccentColor(.accentColor)
                        .dismissButtonStyle(.done)
                        .ignoresSafeArea()
                    }
                }
                
                Section(header: Text("Preferences"), footer: Text("Customize app behavior")) {
                    Picker("Default Tab", selection: $defaultTab) {
                        Text("Upcoming").tag("Upcoming")
                        Text("Results").tag("Results")
                    }
                    .pickerStyle(.menu)
                    
                    Picker("Default Region", selection: $defaultRegion) {
                        ForEach(Array(regionNames.keys.sorted()), id: \.self) { key in
                            Text(regionNames[key] ?? key).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                Button(action: {
                    openMail()
                }) {
                    Label("Contact", systemImage: "envelope.fill")
                }
            }
            .navigationBarTitle("Settings")
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Error"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
            }
        }
    }
    
    private func openMail() {
        let email = "p.szewski@proton.me"
        let subject = "Contact from Flank app"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let body = "\n\n\n\n------------------\nApp Version: \(appVersion)\nBuild Number: \(buildNumber)"
        
        let urlString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        guard let url = URL(string: urlString) else {
            alertMessage = "Could not create email URL"
            showAlert = true
            return
        }
        
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:]) { success in
                if !success {
                    alertMessage = "Could not open mail app"
                    showAlert = true
                }
            }
        } else {
            alertMessage = "No mail app available"
            showAlert = true
        }
    }
}

#Preview {
    SettingsView()
}
