# Codex UI component review

Persistent synthetic proposals for the Codex event → DOM map. The lab contains 28 components, running/completed/failed/waiting scenarios, and review destinations for all 113 installed protocol variants (83 notifications, 11 requests, 19 item types).

Start from the repository root:

```sh
python3 -m http.server 4318 --bind 127.0.0.1
```

Open:

http://127.0.0.1:4318/Resources/SkimRender/dev/codex-ui-preview/

Use **Component** for state/width review, **All components** for the overview, **113 event routes** for native coverage, and **Current renderer** to compare the existing AgentChat replay.

The component hash gives a stable review link, e.g. `#turn-diff`, `#permissions`, `#agent`. Each component's notes, decision and scenario are saved under `floatyterm.codex-ui-review.v1` in localStorage. Export/import JSON provides portable review state. Keep the same origin/port/browser to reuse local storage. Imported entries replace matching component IDs and preserve other entries. Repo files persist independently of the development server.

## Files and extension

- `fixtures.js`: component IDs, representative synthetic payloads and the complete routing inventory. Keep IDs stable so existing notes survive changes. Add a component and assign native routes when the protocol grows.
- `preview.js`: synthetic DOM renderers, lifecycle/state controls, navigation and review persistence. Add a renderer case for each new component ID.
- `preview.css`: scoped lab styling, based on existing SkimRender tokens and typography.
- `index.html`: review workspace and local assets only.
- [Full mapping](../../../../docs/codex-event-dom-map.md): actual bridge behavior and intended destinations.

The shared renderer now includes the remaining event surfaces. **Implemented renderer** opens [the production renderer with synthetic events](../codex-event-surfaces.html); Turn Changes links to [its separate replay](../codex-turn-diff.html). The coverage table records named detail destinations and capability availability. Native permissions, questions and elicitation forms are wired through the host bridge, while these preview buttons remain local simulations. Optional voice transport, embedded provider apps, host tools and credential callbacks are explicitly unavailable in the production host. Payloads are representative rather than complete protocol transcripts.
All interactions stay local. The voice example plays an optional short oscillator tone; it does not capture microphone input. The generated image is a CSS placeholder. Auth, host tools, permissions and requests are simulations. Only the explicitly labeled official documentation link opens an external page.
