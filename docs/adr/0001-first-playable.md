# ADR 0001: First executable slice

Date: 2026-11-15. Status: accepted as reversible implementation defaults under the sprint goal.

The goal explicitly authorizes implementation, superseding the earlier documentation-only stage. Confirmed design decisions in `06-decisions-and-questions.md` retain priority. This ADR does not turn other open design proposals into product decisions.

Use Godot 4.7.2 and GDScript in one process. A renderer-independent RefCounted simulation owns JSON-compatible state. Three independent runtimes consume individual observations; the observer can read the complete state. A composition root connects these components without giving runtime code a simulation reference.

Use one simulated minute per explicit round. The round freezes observations, collects intentions, validates all commands, resolves conflicts with deterministic rotating priority, applies changes, and records transitions. A 1.25-second presentation cadence is only a scheduler for whole rounds. Pause stops scheduling, and reset/load invalidates outstanding capture and model work. Network arrival order never sets resource priority.

Movement uses egocentric displacements limited to one metre. Static wall rectangles are shared by rendering, swept movement checks and visibility. The first floor is a small closed block with an open storage passage and a closed side-room door. Numeric speeds, hearing range, needs costs, field of view and interaction reach are engineering defaults, not validated human physiology or final game balance. No combat, death or treatment is implied.

Model commands do not include global object IDs. Taking and giving resolve a visible reachable target along the character's gaze; inventory commands use only private slot indices. Real VLM input uses actual individual PNGs and an allowlist of private context. Deterministic mock policies additionally use a geometrically filtered diagnostic view. This scaffold is explicitly excluded from real model prompts and is not evidence of VLM perception or behavior.

The observer uses a cutaway view while agent cameras retain full opaque walls. Observer labels and controls live outside the agent viewports. Camera images must be verified with a real renderer, because headless Godot has no valid visual input.

Persistence records initial state, round transitions and events; replay never calls a model. Personal observations, exact PNGs and intentions are saved separately for inspection and session restoration. Raw recent experience is immutable. A separate Memory Agent interface is supplied; subjective compression and personality revision remain unimplemented until a dedicated cycle and its budget are approved.

RouterAI is the primary adapter, with configured alias `~deepseek/deepseek-v4-flash-latest`. Network requests default off. No paid request is authorized by this sprint; enabling and exercising real calls requires explicit user permission and budget. An environment key alone does not authorize a request. Mock responses and local transport tests verify protocol handling only.

Terminal issuance, queueing, devices, diary/photo artifacts and network manipulation remain future scope. Extension interfaces may describe them but must not claim functioning gameplay.
