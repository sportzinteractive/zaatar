#!/bin/bash
# Outlook/Microsoft 365 calendar adapter for Zaatar.
#
# Prints today's Outlook events as a Google-Calendar-shaped JSON array, so it
# can be used directly as ZAATAR_CALENDAR_CMD:
#
#   ZAATAR_CALENDAR_CMD="$HOME/path/to/zaatar/scripts/outlook-calendar.sh"
#
# Requires the Microsoft Graph CLI (`mgc`), authenticated once via:
#   mgc login --scopes Calendars.Read
# Install: https://learn.microsoft.com/en-us/graph/cli/installation
#
# Notes on the Graph -> Google shape mapping (see README "Calendar JSON
# contract" for the fields Zaatar consumes):
#   subject                    -> summary
#   start/end.dateTime         -> start/end.dateTime (Graph omits the tz
#                                 offset; we request UTC and append "Z")
#   onlineMeeting.joinUrl      -> hangoutLink (any video URL works; Zaatar
#                                 also scans location/description for
#                                 Zoom/Teams/Webex/Meet links)
#   attendees[].emailAddress   -> attendees[].displayName/.email
#   location.displayName       -> location
#   bodyPreview                -> description

set -euo pipefail

command -v mgc >/dev/null 2>&1 || {
  echo "outlook-calendar: mgc (Microsoft Graph CLI) not found" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "outlook-calendar: jq not found" >&2
  exit 1
}

DAY_START="$(date -u +%Y-%m-%dT00:00:00Z)"
DAY_END="$(date -u -v+1d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '+1 day' +%Y-%m-%dT00:00:00Z)"

mgc users calendar-view list --user-id me \
  --start-date-time "$DAY_START" --end-date-time "$DAY_END" \
  --headers 'Prefer=outlook.timezone="UTC"' \
  --top 50 \
  --select 'id,subject,start,end,location,bodyPreview,onlineMeeting,attendees,isCancelled' \
  | jq '[.value[]?
      | select(.isCancelled != true)
      | {
          id: .id,
          summary: (.subject // ""),
          start: { dateTime: (.start.dateTime | sub("(\\.[0-9]+)?$"; "") + "Z") },
          end:   { dateTime: (.end.dateTime   | sub("(\\.[0-9]+)?$"; "") + "Z") },
          hangoutLink: (.onlineMeeting.joinUrl // null),
          location: (.location.displayName // ""),
          description: (.bodyPreview // ""),
          attendees: [ .attendees[]?
            | {
                displayName: (.emailAddress.name // ""),
                email: (.emailAddress.address // ""),
                responseStatus: (
                  { accepted: "accepted",
                    declined: "declined",
                    tentativelyAccepted: "tentative",
                    notResponded: "needsAction" }[.status.response] // "needsAction")
              } ]
        }
    ]'
