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
    
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Info"), footer: Text("General app information")) {
                    NavigationLink(destination: AboutView()) {
                        Label("About", systemImage: "info.circle")
                    }
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
        let email = "p.chefski@proton.me"
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
