---
name: create-calendar-event
description: Create a calendar event.
---

# Create calendar event

## Instructions

Call the `run_intent` tool with the following exact parameters:

- intent: create_calendar_event
- parameters: A JSON string with the following fields:
  - title: the title of the event. String.
  - description: an optional description of the event. String.
  - day_offset: how many days from today the event is. Integer. 0 means today,
    1 means tomorrow, 2 means the day after tomorrow, and so on.
  - hour: the start hour in 24-hour time (0–23). Integer.
  - minute: the start minute (0–59). Integer. Defaults to 0.
  - duration_minutes: how long the event lasts, in minutes. Integer. Defaults to 60.

Do NOT ask the user for an exact calendar date, and do NOT compute dates
yourself. Map the user's words directly to `day_offset` and `hour`:

- "today" → day_offset: 0
- "tomorrow" → day_offset: 1
- "in N days" / "the day after tomorrow" → day_offset: N (2 for the day after)
- "3pm" → hour: 15    "noon" → hour: 12    "9am" → hour: 9    "6pm" → hour: 18

Use the title the user already gave; if they gave none, use a short sensible one.
Call the tool immediately — do not ask follow-up questions when the user said a
relative day and a time.

Examples:
- "Create a Team Meeting tomorrow at 3pm" →
  `{ "title": "Team Meeting", "day_offset": 1, "hour": 15 }`
- "Schedule lunch tomorrow at noon for 90 minutes" →
  `{ "title": "Lunch", "day_offset": 1, "hour": 12, "duration_minutes": 90 }`
- "Add a dentist appointment in 3 days at 10am" →
  `{ "title": "Dentist", "day_offset": 3, "hour": 10 }`
- "Gym today at 6pm" →
  `{ "title": "Gym", "day_offset": 0, "hour": 18 }`
