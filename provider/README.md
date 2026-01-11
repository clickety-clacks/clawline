# Clawline Provider

clawd.me provider plugin for Clawline mobile app connections.

## Overview

This provider runs inside the clawd.me plugin system and handles:
- WebSocket connections from Clawline apps
- Pairing flow for new devices
- Token-based authentication
- Message routing to/from agent
- Media handling

## Installation

TBD — will be:
- Built into clawd.me core as a plugin
- Loaded from `.clawd/plugins/*.js`

## Protocol

See `../docs/architecture.md` for the WebSocket message format.

## Plugin installation

The Clawline provider runs as a clawd plugin. Use the helper located in `provider/plugins/clawline-provider.js`:

1. Build the provider (see below).
2. Copy or symlink `provider/plugins/clawline-provider.js` into `~/.clawd/plugins/`.
3. Ensure the plugin can find the compiled provider:
   - By default it looks for `../dist/index.js` (when symlinked) or `~/src/clawline/provider/dist/index.js`.
   - You can override by setting `CLAWLINE_PROVIDER_DIST=/absolute/path/to/dist/index.js`.
4. Restart clawd so it loads the new plugin.

The plugin deep-merges a `clawline` block from clawd’s config. For testing it defaults to:

```json
{
  "port": 18792,
  "network": {
    "bindAddress": "0.0.0.0",
    "allowInsecurePublic": true,
    "allowedOrigins": ["null"]
  }
}
```

Override these fields in clawd’s config before production use (e.g., bind to your Tailscale IP or re-enable localhost).

## Build

```
cd provider
npm install
npm run build
```

`npm run build` compiles the TypeScript sources with `tsc -p tsconfig.build.json`, preserving the normal Node.js module resolution so native dependencies such as `better-sqlite3` continue to load from `node_modules/`.

## Configuration

```json
{
  "clawline": {
    "enabled": true,
    "statePath": "~/.clawd/clawline",
    "port": 18792,
    "network": {
      "bindAddress": "127.0.0.1",
      "allowInsecurePublic": false
    },
    "adapter": null,
    "auth": {
      "jwtSigningKey": null,
      "tokenTtlSeconds": 31536000,
      "maxAttemptsPerMinute": 5,
      "reissueGraceSeconds": 600
    },
    "pairing": {
      "maxPendingRequests": 100,
      "maxRequestsPerMinute": 5,
      "pendingTtlSeconds": 300
    },
    "media": {
      "maxInlineBytes": 262144,
      "maxUploadBytes": 104857600,
      "unreferencedUploadTtlSeconds": 3600,
      "storagePath": "~/.clawd/clawline-media"
    },
    "sessions": {
      "maxMessageBytes": 65536,
      "maxReplayMessages": 500,
      "maxPromptMessages": 200,
      "maxMessagesPerSecond": 5,
      "maxTypingPerSecond": 2,
      "typingAutoExpireSeconds": 10,
      "maxQueuedMessages": 20,
      "maxWriteQueueDepth": 1000,
      "adapterExecuteTimeoutSeconds": 300,
      "streamInactivitySeconds": 300
    },
    "streams": {
      "chunkPersistIntervalMs": 100,
      "chunkBufferBytes": 1048576
    }
  }
}
```

Notes:
- `statePath` stores allowlist/denylist and SQLite metadata.
- `media.storagePath` stores large-file bytes and may be separate.
- `media.maxInlineBytes` applies to the total decoded inline attachment bytes per message.
