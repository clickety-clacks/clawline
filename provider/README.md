# Clawline Provider

Clawdbot provider for Clawline mobile app connections.

## Overview

This provider runs inside the Clawdbot gateway and handles:
- WebSocket connections from Clawline apps
- Pairing flow for new devices
- Token-based authentication
- Message routing to/from agent
- Media handling

## Installation

TBD — will either be:
- Built into Clawdbot core
- Loaded as a plugin
- Copied to gateway instance

## Protocol

See `../docs/protocol.md` for the WebSocket message format.

## Configuration

```json
{
  "clawline": {
    "enabled": true,
    "port": 18792,
    "pairing": {
      "approvalChannel": "telegram"
    }
  }
}
```
