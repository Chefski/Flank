//
//  UpcomingMatchTab.swift
//  Flank
//
//  Created by Patryk Radziszewski on 22/04/2024.
//

import SwiftUI
import EventKit
import MarqueeText
import SafariServices
import BetterSafariView
import Foundation

struct UpcomingMatchTab: View {
    let match: UpcomingMatch
    
    @State private var isExpanded = false
    @State private var presentingSafariView = false
    @State private var showingCalendarAlert = false
    @State private var calendarAlertMessage = ""
    
    var body: some View {
        VStack(spacing: 0) {
            LazyVStack {
                Text("\(match.time_until_match) (@ \(formatMatchTime(unixTimestamp: match.unix_timestamp)))")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(0.75)
                Spacer()
                HStack{
                    VStack {
                        let teamName = match.team1.hasSuffix(" GC") ? String(match.team1.dropLast(3)) : match.team1
                        Image(uiImage: UIImage(named: teamName) ?? UIImage(named: "unknown_team")!)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 46, height: 46)
                        Text(match.team1)
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 115)
                            .multilineTextAlignment(.center)
                    }
                    Text(emoji(for: match.flag1))
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 24, height: 24)
                        .padding(3)
                        .background(.white.opacity(0.1))
                        .cornerRadius(49)
                        .overlay(
                            RoundedRectangle(cornerRadius: 49)
                                .inset(by: 0.25)
                                .stroke(.white.opacity(0.1), lineWidth: 0.5)
                        )
                    Text("vs")
                        .font(.system(size: 15, weight: .bold))
                        .frame(minWidth: 24, maxWidth: 40)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(emoji(for: match.flag2))
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 24, height: 24)
                        .padding(3)
                        .background(.white.opacity(0.1))
                        .cornerRadius(49)
                        .overlay(
                            RoundedRectangle(cornerRadius: 49)
                                .inset(by: 0.25)
                                .stroke(.white.opacity(0.1), lineWidth: 0.5)
                        )
                    VStack {
                        let teamName = match.team2.hasSuffix(" GC") ? String(match.team2.dropLast(3)) : match.team2
                        Image(uiImage: UIImage(named: teamName) ?? UIImage(named: "unknown_team")!)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 46, height: 46)
                        Text(match.team2)
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 115)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
                Spacer()
                VStack {
                    Text(match.match_event)
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.75)
                    Text(match.match_series)
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.75)
                }
            }
            .frame(height: 175)
            .background(
                LinearGradient(
                    stops: [
                        Gradient.Stop(color: .white.opacity(0), location: 0.00),
                        Gradient.Stop(color: Color(red: 0.42, green: 0.3, blue: 0.17).opacity(0.2), location: 1.00),
                    ],
                    startPoint: UnitPoint(x: 0, y: 0.5),
                    endPoint: UnitPoint(x: 1, y: 0.5)
                )
            )
            .background(Color(red: 0.08, green: 0.08, blue: 0.08))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .inset(by: 0.5)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .zIndex(1)
            
            // Expanding card
            VStack {
                HStack {
                    Button(action: {
                        requestCalendarAccess { granted in
                            if granted {
                                if let date = convertUnixTimestampToDate(unixTimestamp: match.unix_timestamp) {
                                    addEventToCalendar(date: date, matchTitle: "\(match.team1) vs \(match.team2)")
                                }
                            } else {
                                calendarAlertMessage = "Calendar access is required to add events. Please enable it in Settings."
                                showingCalendarAlert = true
                            }
                        }
                    }) {
                        Label("Add to Calendar", systemImage: "calendar.badge.plus")
                            .font(.system(size: 12))
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .alert(isPresented: $showingCalendarAlert) {
                        Alert(title: Text("Calendar Access"), message: Text(calendarAlertMessage), dismissButton: .default(Text("OK")))
                    }
                    
                    Button(action: {
                        self.presentingSafariView = true
                    }) {
                        Label("View on vlr.gg", systemImage: "arrow.up.right.square.fill")
                            .font(.system(size: 12))
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding()
            }
            .frame(height: isExpanded ? 80 : 0)
            .opacity(isExpanded ? 1 : 0)
            .background(Color(red: 0.08, green: 0.08, blue: 0.08))
            .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0 , bottomLeading: 20, bottomTrailing: 20, topTrailing: 0)))
            .overlay(
                UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0 , bottomLeading: 20, bottomTrailing: 20, topTrailing: 0))
                    .inset(by: 0.5)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .offset(y: -2)
            .zIndex(0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0), value: isExpanded)
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0)) {
                isExpanded.toggle()
            }
        }
        .sheet(isPresented: $presentingSafariView) {
            SafariView(
                url: URL(string: match.match_page)!,
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
    
    private func convertUnixTimestampToDate(unixTimestamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: unixTimestamp)
    }
    
    private func requestCalendarAccess(completion: @escaping (Bool) -> Void) {
        let eventStore = EKEventStore()
        
        if #available(iOS 17.0, *) {
            eventStore.requestWriteOnlyAccessToEvents { granted, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error requesting calendar access: \(error.localizedDescription)")
                        completion(false)
                    } else {
                        completion(granted)
                    }
                }
            }
        } else {
            // Fallback for iOS versions prior to 17.0
            eventStore.requestAccess(to: .event) { granted, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error requesting calendar access: \(error.localizedDescription)")
                        completion(false)
                    } else {
                        completion(granted)
                    }
                }
            }
        }
    }
    
    private func addEventToCalendar(date: Date, matchTitle: String) {
        let eventStore = EKEventStore()
        
        func saveEvent() {
            let event = EKEvent(eventStore: eventStore)
            event.title = matchTitle
            event.startDate = date
            event.endDate = date.addingTimeInterval(7200) // 2 Hours
            event.calendar = eventStore.defaultCalendarForNewEvents
            
            do {
                try eventStore.save(event, span: .thisEvent)
                calendarAlertMessage = "Event added to calendar successfully!"
                showingCalendarAlert = true
            } catch {
                calendarAlertMessage = "Failed to save event: \(error.localizedDescription)"
                showingCalendarAlert = true
            }
        }
        
        if #available(iOS 17.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .writeOnly:
                saveEvent()
            case .notDetermined:
                requestCalendarAccess { granted in
                    if granted {
                        saveEvent()
                    } else {
                        self.calendarAlertMessage = "Calendar access denied."
                        self.showingCalendarAlert = true
                    }
                }
            case .restricted, .denied:
                calendarAlertMessage = "Calendar access is restricted or denied. Please check your settings."
                showingCalendarAlert = true
            @unknown default:
                calendarAlertMessage = "Unknown calendar authorization status."
                showingCalendarAlert = true
            }
        } else {
            // Fallback for iOS versions prior to 17.0
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized:
                saveEvent()
            case .notDetermined:
                requestCalendarAccess { granted in
                    if granted {
                        saveEvent()
                    } else {
                        self.calendarAlertMessage = "Calendar access denied."
                        self.showingCalendarAlert = true
                    }
                }
            case .restricted, .denied:
                calendarAlertMessage = "Calendar access is restricted or denied. Please check your settings."
                showingCalendarAlert = true
            @unknown default:
                calendarAlertMessage = "Unknown calendar authorization status."
                showingCalendarAlert = true
            }
        }
    }
    
    private func formatMatchTime(unixTimestamp: String) -> String {
                let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.timeZone = TimeZone.current
        
        if let date = dateFormatter.date(from: unixTimestamp) {
            dateFormatter.dateFormat = "HH:mm"
            return dateFormatter.string(from: date)
        }
        
        if let timeInterval = Double(unixTimestamp) {
            let date = Date(timeIntervalSince1970: timeInterval)
            dateFormatter.dateFormat = "HH:mm"
            return dateFormatter.string(from: date)
        }
        return "Unknown time"
    }
}

struct UpcomingMatchTab_Previews: PreviewProvider {
    static var previews: some View {
        let mockMatch = UpcomingMatch(team1: "Akave Esports GC", team2: "FNATIC", flag1: "flag_br",
                                      flag2: "flag_us", time_until_match: "2h 45m from now",  match_series: "Regular Season: Week 4", match_event: "Champions Tour 2024: Americas Stage 1", unix_timestamp: "2024-04-17 09:00:00", match_page: "https://google.com")
        UpcomingMatchTab(match: mockMatch)
    }
}
