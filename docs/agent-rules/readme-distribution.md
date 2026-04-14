# README, Distribution, and About Screen Rules

Read this file when the task touches README, installation instructions, distribution notes, About screen, licensing text, or end-user run instructions.

## README and Distribution

- Default to MIT license unless I specify otherwise.
- For personal apps, hobby projects, or largely vibe-coded repos, the README MUST say that plainly near the top when it is materially true. It should make clear that the project primarily exists to satisfy the owner's needs, that outside usefulness is incidental, and that no warranties, support commitments, stability guarantees, or roadmap promises are implied beyond the actual license.
- If a repo ships a user-facing app that is not notarized, not signed for public distribution, or otherwise likely to trigger OS security warnings, the README should disclose that explicitly and include safe, user-facing steps for running it.
- On macOS: Finder Open or System Settings > Privacy & Security > Open Anyway.
- On Windows: Properties -> Unblock or "Run anyway" from SmartScreen.
- Prefer platform UI guidance over shell-based bypass instructions unless advanced troubleshooting is specifically requested.
- For personal macOS apps where I have not chosen to pay for Apple Developer Program membership and notarization, the README should say that plainly. It should explain that these are personal-use apps, that notarization is intentionally not being paid for, and that users can still open the app by attempting launch once and then going to `System Settings -> Privacy & Security -> Open Anyway`.
- When packaging apps, prefer portable builds that run across supported machine architectures when practical, such as universal macOS binaries. Do not lower deployment targets, broaden compatibility claims, or change minimum supported OS versions without explicit approval. If a build remains host-specific or requires external third-party files, say so clearly in the README or release notes.

## About Screen

- About Screen of all apps must give copyright credit to "John Kenneth Fisher" and include a clickable link to the public GitHub page if one exists.
