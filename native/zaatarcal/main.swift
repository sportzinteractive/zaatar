#!/usr/bin/swift
// zaatarcal - Native calendar bridge for Zaatar using EventKit.
// Works with any calendar provider configured in macOS (Google, Outlook,
// iCloud, Exchange). No OAuth, no API keys, no external dependencies.
//
// Usage: zaatarcal [--days N]
// Outputs today's events (or next N days) as a JSON array matching the
// Google Calendar API shape that meet-watch.sh expects.
//
// First run triggers a macOS calendar access permission prompt.

import EventKit
import Foundation

let store = EKEventStore()

// Parse args
var days = 1
if let idx = CommandLine.arguments.firstIndex(of: "--days"),
   idx + 1 < CommandLine.arguments.count,
   let n = Int(CommandLine.arguments[idx + 1]) { days = n }

// Request calendar access (blocks until user responds on first run)
let semaphore = DispatchSemaphore(value: 0)
var granted = false
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { ok, _ in granted = ok; semaphore.signal() }
} else {
    store.requestAccess(to: .event) { ok, _ in granted = ok; semaphore.signal() }
}
semaphore.wait()

guard granted else {
    fputs("zaatarcal: calendar access denied. Grant in System Settings > Privacy > Calendars.\n", stderr)
    print("[]")
    exit(0)
}

// Fetch events
let cal = Calendar.current
let startOfDay = cal.startOfDay(for: Date())
guard let endDate = cal.date(byAdding: .day, value: days, to: startOfDay) else {
    print("[]"); exit(0)
}
let predicate = store.predicateForEvents(withStart: startOfDay, end: endDate, calendars: nil)
let events = store.events(matching: predicate)

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime]

// Regex patterns for meeting URLs
let meetPatterns: [(String, NSRegularExpression?)] = [
    ("meet", try? NSRegularExpression(pattern: "https://meet\\.google\\.com/[a-z-]+")),
    ("zoom", try? NSRegularExpression(pattern: "https://[a-zA-Z0-9.]*zoom\\.us/[jmys]/[a-zA-Z0-9?=&._%-]+")),
    ("teams", try? NSRegularExpression(pattern: "https://teams\\.(microsoft\\.com/l/meetup-join|live\\.com/meet)/[a-zA-Z0-9?=&._%-]+")),
    ("webex", try? NSRegularExpression(pattern: "https://[a-zA-Z0-9.]*webex\\.com/(meet|join)/[a-zA-Z0-9?=&._%-]+")),
]

func findMeetURL(_ texts: [String]) -> String? {
    for text in texts {
        let range = NSRange(text.startIndex..., in: text)
        for (_, regex) in meetPatterns {
            guard let regex else { continue }
            if let match = regex.firstMatch(in: text, range: range) {
                return String(text[Range(match.range, in: text)!])
            }
        }
    }
    return nil
}

// Build JSON array matching Google Calendar API shape
var result: [[String: Any]] = []

for ev in events {
    guard let start = ev.startDate, let end = ev.endDate else { continue }

    let searchTexts = [ev.location ?? "", ev.notes ?? "", ev.url?.absoluteString ?? ""]
    let meetURL = findMeetURL(searchTexts)

    // Attendees
    var attendees: [[String: Any]] = []
    for p in ev.attendees ?? [] {
        var att: [String: Any] = [:]
        att["displayName"] = p.name ?? ""
        // EKParticipant email is in the URL property (mailto:user@example.com)
        if let email = p.url.absoluteString
            .replacingOccurrences(of: "mailto:", with: "")
            .removingPercentEncoding {
            att["email"] = email
        }
        att["self"] = p.isCurrentUser
        att["resource"] = (p.participantType == .room || p.participantType == .resource)
        switch p.participantStatus {
        case .accepted: att["responseStatus"] = "accepted"
        case .declined: att["responseStatus"] = "declined"
        case .tentative: att["responseStatus"] = "tentative"
        default: att["responseStatus"] = "needsAction"
        }
        attendees.append(att)
    }

    var event: [String: Any] = [
        "id": ev.eventIdentifier ?? UUID().uuidString,
        "summary": ev.title ?? "meeting",
        "start": ["dateTime": iso.string(from: start)],
        "end": ["dateTime": iso.string(from: end)],
        "attendees": attendees,
        "location": ev.location ?? "",
        "description": ev.notes ?? "",
    ]

    if let url = meetURL {
        event["hangoutLink"] = url
        event["conferenceData"] = [
            "entryPoints": [["entryPointType": "video", "uri": url]]
        ]
    }

    result.append(event)
}

// Output
let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8) ?? "[]")
