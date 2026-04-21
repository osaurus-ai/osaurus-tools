---
name: osaurus-time
description: Teaches the agent how to use the time tools — current time, timezone conversion, parsing dates, formatting, date arithmetic.
metadata:
  author: Osaurus
  version: "2.0.0"
---

# Time

A small, pure-function toolkit for clock and calendar work. No network, no state.

## When to use

- Stamping outputs with the user's current time, in the user's timezone.
- Converting a timestamp to a different timezone for display.
- Parsing a date the user mentions in natural form ("2025-04-21", "Mon, 21 Apr 2025 14:00:00 GMT") to a comparable Unix timestamp.
- Adding or subtracting durations from a date ("3 days from now", "2 hours before that meeting").
- Computing the difference between two dates.

## When NOT to use

- Sleeping/blocking the agent loop — these tools do not block.
- Recurring schedules — use the host app's automation/Schedules surface.
- Scheduling reminders — use `osaurus.reminders`.

## Canonical workflow

1. Call `current_time` once at the start of any task that needs "now". Pass the user's timezone if you know it; otherwise omit and the system zone is used.
2. Use `parse_date` to turn user-supplied strings into a Unix timestamp before doing any math.
3. Use `add_duration` / `diff_dates` for arithmetic.
4. Use `format_date` only at the end, when you need a human-readable string.

## Output envelope

Every tool returns:

```json
{ "ok": true,  "data": { ... }, "warnings": ["..."] }
{ "ok": false, "error": { "code": "INVALID_ARGS", "message": "...", "hint": "..." } }
```

Always check `ok` before reading `data`. Bad timezone IDs and unparseable date strings produce structured errors — don't swallow them.

## Tips

- IANA timezone IDs only (`America/New_York`, not `EST`). Call `list_timezones` if you need to validate one.
- `relative` format is locale-controlled; pass `locale: "en_US"` for stable English output.
- `add_duration` accepts ISO 8601 durations like `P1DT2H` (1 day, 2 hours) or signed seconds.
