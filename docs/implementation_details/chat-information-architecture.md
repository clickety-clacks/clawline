# Chat Information Architecture — Non-Obvious Details

## Client NEVER constructs DM session keys — they come from the provider
The client never parses or constructs DM session keys. The provider receives the resolved DM key from OpenClaw core and passes it to the client. DM key format varies with `dmScope` configuration. Any iOS code that constructs a DM session key from known patterns is wrong and will break with `dmScope` config changes.

## Delivery target ≠ session identity
`delivery target` format (`flynn:main`, `flynn:dm`) is a wire protocol detail for routing messages in transit. `session key` is conversation identity (history, context, agent). These are separate concepts. Confusing them produces messages that deliver to the right agent but get recorded in the wrong conversation history.

## `dmScope` affects whether Personal DM stream is visible to non-admins
- `dmScope=main` (global): all DMs share `agent:main:main`, no separate Personal DM stream per user
- Any other value: each user gets their own DM session — Personal DM stream is visible to non-admins

Non-admins only see the Personal DM stream when `dmScope` creates per-user isolation. Admin-only visibility of the global DM stream (`agent:main:main`) is independent of this.
