//
//  AboutView.swift
//  Flank
//
//  Created by Patryk Radziszewski on 26/04/2024.
//

import SwiftUI
import LookingGlassUI
import BetterSafariView

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vlrggSite = false
    
    var body: some View {
        NavigationStack {
            VStack() {
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 31))
                    .overlay(
                        RoundedRectangle(cornerRadius: 31)
                            .inset(by: 0.5)
                            .stroke(.white, lineWidth: 1)
                            .opacity(0.15)
                    )
                    .shimmer(color: .white.opacity(0.4))
                Text("Flank")
                    .font(.system(size: 36, weight: .bold))
                Text("V\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"))")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.70)
                Spacer()
                    .frame(height: 40)
                Text("Made with 🍀 by \nPatryk Radziszewski in 🇮🇪")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                Spacer()
                Text("Data provided by")
                    .fontWeight(.semibold)
                    .opacity(0.75)
                Button {
                    self.vlrggSite = true
                } label: {
                    Image("vlrggLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70, height: 70)
                }
            }
            .sheet(isPresented: $vlrggSite) {
                SafariView(
                    url: URL(string: "https://www.vlr.gg/")!,
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
            .padding()
            .navigationTitle("About")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.black)
                            .padding(6)
                            .background(
                                Circle()
                                    .fill(.white)
                            )
                    }
                }
            }
            .motionManager(updateInterval: 0.1, disabled: false)
        }
    }
}

#Preview {
    AboutView()
}
