# Windows Platform Rules

Read this when the task touches Windows builds, installers, PowerShell, path handling, WinUI/Fluent conventions, Windows packaging, SmartScreen, Windows signing/resources, or Windows CI behavior.

Do not read this for non-Windows tasks.

## Windows platform

Prefer platform-native appearance and controls where feasible. For native Windows apps, follow Fluent/WinUI conventions. In cross-platform projects, accept visual differences rather than forcing a single aesthetic.

Windows builds should be unsigned unless the user explicitly sets up code signing.

Prefer portable or per-user installs over system-wide MSI installers unless the project requires it. Avoid requiring admin elevation for basic app functionality.

Handle Windows path length limits, reserved filenames such as `CON`, `PRN`, and `NUL`, and backslash vs forward slash differences explicitly. Do not assume Unix path behavior.

For Windows CI builds, do not assume Unix shell commands. Use PowerShell or ensure cross-shell compatibility. Tauri cross-platform builds may also need the Tauri and CI/release rules.

## Native Windows conventions

Prefer native Windows conventions for paths, installers, resources, signing, and user expectations.

Do not assume Unix-style paths, shell behavior, file permissions, or packaging norms apply on Windows.
