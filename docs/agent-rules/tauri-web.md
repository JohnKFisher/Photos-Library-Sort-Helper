# Web / Tauri Frontend Rules

Read this file when the project uses Tauri, Rust + WebView architecture, frontend frameworks inside Tauri, IPC bridges, or desktop web UI code.

## Web / Tauri Frontend

- For Tauri apps, the web frontend is the UI layer — not a standalone web app. Keep frontend dependencies minimal and justified.
- Prefer vanilla HTML/CSS/JS or a lightweight framework unless the project's complexity clearly warrants a heavier one. Do not introduce React, Vue, or similar without justification and approval.
- Respect the Tauri security model: use the IPC bridge for system access, do not attempt to bypass Tauri's API allowlist, and keep the frontend sandboxed from direct filesystem/OS access.
- If the frontend needs to work across macOS and Windows Tauri shells, test for and handle platform rendering differences (WebView2 on Windows vs WebKit on macOS).
