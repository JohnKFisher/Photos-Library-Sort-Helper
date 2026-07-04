# Web and Static Site Platform Rules

Read this when the task touches ordinary website/frontend/browser UI work, static sites, Sidelark Labs site work, Cloudflare Pages-style projects, HTML/CSS/JavaScript, public site content, or web build/deploy behavior.

Do not read this for Tauri desktop webview work; use `platform-tauri.md` for that.

## Web defaults

Prefer simple static/frontend approaches unless project complexity clearly requires a heavier framework.

Keep dependencies minimal and justified. Do not introduce a new framework, build system, or deployment platform without approval.

Prioritize:

- fast loading,
- accessible semantic HTML,
- responsive layouts,
- system-friendly colors and typography,
- clear navigation,
- minimal JavaScript where practical.

## Public site content

Avoid hype, fake corporate polish, and long marketing copy. For Sidelark Labs projects, keep project pages clear and point users to the right app/support/privacy/changelog pages.

## Deployment/build caution

Do not change DNS, Cloudflare settings, deployment commands, redirects, build output directories, or environment variables without explicit approval.
