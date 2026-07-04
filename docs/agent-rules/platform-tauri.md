# Tauri Platform Rules

Read this when the project uses Tauri, Rust + WebView architecture, frontend frameworks inside Tauri, IPC bridges, desktop web UI code, WebView2/WebKit differences, or Tauri security/packaging.

Do not read this for ordinary static websites unless they are inside a Tauri app.

## Tauri architecture

For Tauri apps, the web frontend is the UI layer, not a standalone web app. Keep frontend dependencies minimal and justified.

Prefer vanilla HTML/CSS/JS or a lightweight framework unless complexity clearly warrants a heavier one. Do not introduce React, Vue, or similar without justification and approval.

Respect the Tauri security model:

- use the IPC bridge for system access,
- do not bypass Tauri's API allowlist,
- keep the frontend sandboxed from direct filesystem/OS access,
- validate IPC inputs and outputs.

If the frontend must work across macOS and Windows shells, test for and handle platform rendering differences such as WebView2 on Windows vs WebKit on macOS.

## Tauri boundaries

Keep Tauri boundaries explicit.

Do not blur frontend, Rust backend, filesystem, shell, IPC, and permission responsibilities. Avoid broad or unsafe IPC commands when narrow commands solve the task.
