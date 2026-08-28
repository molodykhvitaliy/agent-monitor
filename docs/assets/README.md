# Presentation assets

Images the repository's public face is made of. Nothing here is compiled into the
app — the app's own icon is `Apps/AgentBar/AgentBar.icon`, and this directory
holds what GitHub renders.

| File | Where it is used | How it was made |
|---|---|---|
| `agentbar-icon.png` | the README heading | `NSWorkspace.icon(forFile:)` on the built bundle at 1024 px, resampled to 512 — the composed icon macOS actually draws, not a redraw of the layers |
| `screenshots/*.png` | the README | `screencapture -l <windowID>` against a running 0.9.0 build, so each frame contains AgentBar's own window and nothing else on the screen |
| `social-preview.png` | **uploaded by hand** — Settings › General › Social preview | rendered from the icon and the design system's palette; 1280 × 640, under GitHub's 1 MB limit |

`social-preview.png` is the one asset no workflow can install: GitHub exposes the
social preview only through the web interface, so a fresh fork or a transferred
repository has to have it set again by a person.

Screenshots are of real sessions. If you replace one, capture a window rather
than a region — a region capture puts whatever is behind the panel into a public
image.
