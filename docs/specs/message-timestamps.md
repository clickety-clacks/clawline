# Message Bubble Timestamps

**Status:** Implementation  
**Issue:** T115  
**Mockup:** http://tars.tail4105e8.ts.net:18800/www/timestamp-mockups.html (Option 5)

## Goal

Add human-readable timestamps to message bubbles showing when each message was sent.

## Design

Ultra-minimal treatment (10px, 40% opacity) — visible when looking for it, invisible at a glance.

### Position & Layout

- Right-aligned in message header with 20px padding from right edge
- Baseline aligns with sender name baseline
- **Do NOT change existing avatar/sender name positioning** (already correct)

### Visual Styling

- Font size: 10px
- Color: design system `text-muted`
- Opacity: 0.4 (40%)
- Letter spacing: 0.2px

### Format Rules

**Recent messages (< 24 hours):**
- Relative time in short form
- Examples: "5m ago", "2h ago", "23h ago"
- Use single letter abbreviations: m (minutes), h (hours)

**Older messages (≥ 24 hours):**
- Shortened date/time format
- Today: not applicable (use relative)
- Yesterday: "Yesterday 3:42 PM"
- This week: "Mon 11:30 AM", "Tue 3:15 PM"
- Older: "Feb 21 11:30 AM", "Jan 15 2:45 PM"
- Different year: "Dec 25, 2025 10:00 AM"

### Implementation Notes

- Timestamp data comes from message metadata (already available)
- Update timestamp text periodically for relative times
- No need to update timestamps for absolute dates
- Consider updating relative timestamps every minute for messages < 1 hour old
- Messages 1-24 hours old can update less frequently

### SwiftUI Structure

Current message header structure (do not change):
```
HStack(alignment: .center) {
    Avatar (circle, vertically centered)
    Text(senderName) (vertically centered to avatar)
}
```

Add timestamp:
```
HStack(alignment: .center) {
    Avatar (circle, vertically centered)
    HStack(alignment: .firstTextBaseline) {
        Text(senderName)
        Spacer()
        Text(timestamp)
            .font(.system(size: 10))
            .foregroundColor(theme.textMuted)
            .opacity(0.4)
            .kerning(0.2)
    }
}
```

This keeps the avatar centered while allowing sender name and timestamp to share a baseline.

## Design System Compliance

- Uses design system `text-muted` color token
- Follows design system spacing (20px bubble horizontal padding)
- Respects existing message header alignment
- Ultra-minimal aesthetic matches organic modernist philosophy

## Accessibility

- 10px text at 40% opacity is below WCAG minimum contrast for critical content
- This is acceptable because timestamps are supplementary metadata, not primary content
- Users who need timestamps can still read them, but they don't compete with message content
- Consider VoiceOver support: include timestamp in bubble's accessible label

## Future Enhancements

- Show full timestamp on long-press/tooltip
- Group messages by date with date dividers
- "Today", "Yesterday" section headers in long conversations
