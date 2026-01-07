# Clawline

A native iOS/Android chat app for communicating with your [Clawd](https://clawd.me) assistant.

## What is Clawd?

[Clawd](https://clawd.me) is a personal AI assistant platform. Clawline gives you a dedicated mobile interface to chat with your Clawd instance — with slick native animations, media support, and secure pairing.

## Structure

- `ios/` — Swift/SwiftUI project
- `android/` — Kotlin/Jetpack Compose project
- `provider/` — Clawdbot provider (WebSocket connector)
- `shared/` — Assets, icons, API specs
- `docs/` — Protocol docs, design notes
- `prompts/` — LLM translation prompts that work well

## Architecture

- **Native-first**: Swift on iOS, Kotlin on Android (no React Native)
- **LLM-assisted development**: Code translated between platforms using AI
- **Custom provider**: Connects to Clawd gateway via WebSocket
- **Secure pairing**: Token-based identity with approval flow

## Status

🚧 Early development

## License

MIT
