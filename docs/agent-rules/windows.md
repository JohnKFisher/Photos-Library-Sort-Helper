# Windows Platform Rules

Read this file when the task touches Windows builds, installers, PowerShell, path handling, WinUI/Fluent conventions, Windows packaging, SmartScreen, or Windows signing/resources.

## Windows Platform

- Prefer platform-native appearance and controls where feasible. For native Windows apps, follow Fluent/WinUI conventions. When the same codebase targets both macOS and Windows, accept visual differences between platforms rather than forcing a single aesthetic.
- Windows builds should be unsigned unless I explicitly set up code signing.
- Prefer portable or per-user installs over system-wide MSI installers unless the project specifically requires it. Avoid requiring admin elevation for basic app functionality.
- Handle Windows path length limits (MAX_PATH), reserved filenames (CON, PRN, NUL, etc.), and backslash vs forward slash differences explicitly. Do not assume Unix path behavior.
- For Windows CI builds, do not assume Unix shell commands — use PowerShell or ensure cross-shell compatibility. This applies to native Windows projects; Tauri cross-platform builds are covered in the CI section.
