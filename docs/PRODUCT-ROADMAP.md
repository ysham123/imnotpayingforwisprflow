# Local Dictation: voice for the agent you chose

Product proposal, 2026-10-09. The creator selected **talk to coding agents while browsing** as the first workflow. The placement fix is implemented separately in 2.0.1; the integrations and redesigned interface below are proposed work.

## Product promise

Choose the project and agent session once, then speak to it while reading documentation or working elsewhere. The destination stays visible and stable. The app carries the request, selected supporting material, delivery status, and the agent's response through one small interface.

Example: pin the agent working on Local Dictation, browse an API reference, select a paragraph, then say “Use this API for the microphone selector. Keep the current fallback behavior.” Review the request and attached source, send it to that exact session, keep reading, and see its reply without hunting through terminal tabs.

Dictation remains the default local feature. An agent request is an explicit destination with a separate shortcut or mode. Speaking ordinary text must never accidentally invoke a model, start a search, or send a command.

## What already exists

| Product | Documented overlap | Implication |
|---|---|---|
| Superwhisper | BYOK language models; coding-agent voice replies, completion notifications, and spoken approvals across several agents. | Neither BYOK nor voice-to-agent communication is a unique claim. [Models](https://superwhisper.com/docs/models/language), [agent integrations](https://superwhisper.com/docs/get-started/coding-agents). |
| Raycast | Custom and local model providers plus optional web-search/page-reading tools. | A general desktop AI assistant would compete on an already broad feature set. [Custom providers](https://manual.raycast.com/ai/custom-providers). |
| Wispr Flow | Its documented remote MCP connector exposes meeting/Scratchpad notes read-only, excluding dictation and Notetaker chat history. | “Has MCP” is not a meaningful product differentiator; compare the actual workflow and direction of access. [Connector scope](https://docs.wisprflow.ai/articles/9551372685-connect-an-mcp-client-to-wispr-flow-remote-mcp-server). |

These are documentation comparisons, not hands-on product benchmarks. The opportunity is a hypothesis: reliable routing to an existing project/session, transparent source attachments, exact prompt preservation, and a simple local product may make the research-to-agent handoff better. No exclusive-feature claim is established by this research.

## Build order

### Foundation: placement and installation

Ship and validate the 2.0.1 original-field fix in native apps, Chrome, and Electron, including changed documents and closed targets. Show the captured destination in the next HUD design. Treat permission continuity as a release requirement: use a persistent signing identity, verify clean installs, unchanged relaunches, and upgrades between two differently built signed versions. The current ad-hoc releases cannot promise grant continuity across updates. Do not change a working installed binary while diagnosing a plain quit/reopen failure.

### First vertical slice: one agent, one session, one reply

Start with an explicit connection and named session picker. Store agent type, connection identity, project, and session ID together. A turn snapshots that destination; later app/tab switches cannot change it. The draft can be reviewed, edited, sent, canceled, or retained after disconnect. Show the session's response and a quiet completion notification in the same panel.

Use one supported agent adapter first. OpenCode is the reference feasibility target because its official server exposes session listing, messages, asynchronous prompts, and events. Pin a supported version and query its schema; do not assume development/v2 routes equal the installed stable API. [OpenCode server](https://opencode.ai/docs/server/).

Before choosing the shipping adapter, confirm the creator's daily agent and prove attaching to an already-running session, receiving replies, busy-state handling, and reconnection. Claude Code hooks supply lifecycle/session information, but event hooks alone do not establish a general prompt-submission channel. Codex, Claude Code, and other adapters each need a verified transport before being advertised. [Claude Code hooks](https://code.claude.com/docs/en/hooks).

If an agent offers no session-aware transport, label the fallback **Paste into terminal**. It requires a visible chosen destination and does not submit Enter. Never identify a session using a window title alone or type into an arbitrary shell. Preserve terminal execution risks separately from ordinary editor insertion.

The agent uses its existing model connection. This workflow should not require an additional LLM key or an extra model call just to forward a prompt.

### Browser context: attach what the user chose

Add an optional browser companion with a deliberate “Attach selection” action. Include the page title, URL, selected excerpt, and capture time in a removable preview. Bind that snapshot to the turn so navigating away cannot silently replace it. Start with one browser; a manually pasted URL/excerpt is the initial fallback.

Keep public web search separate from reading the current browser tab. Search needs a supported search tool/provider, result URLs, and citations. Authenticated tabs need the user's explicit context selection; an API key does not provide browser-session access. Add search only after the handoff workflow works. General autonomous browser clicking is outside the first release.

### BYOK Ask mode and broader adapters

Add one well-supported remote model connection plus an optional local endpoint, then expand by tested capabilities. Connection settings contain provider, endpoint, model, and a Keychain-backed credential reference. Offer connection testing, streaming replies, cancellation, bounded request sizes, and clear errors for expired credentials or limits. Label local versus remote processing before sending.

An API connection creates the app's own model conversation; it does not automatically attach to an existing consumer chat or import its history. Existing chats use explicit composer placement or a supported connector with a verified conversation identity. Each search provider is another capability and may require its own credentials.

## Popup behavior

- **Dictate:** a compact, nonactivating listening pill with elapsed time, mic level, destination, and cancel. Keep the editor's focus; no live transcript is required.
- **Agent:** the compact pill names the pinned project/session. Finishing opens a deliberate review card with the request and removable source attachments. Sending shows queued, acknowledged, working, waiting for input, completed, or uncertain delivery as distinct states.
- **Ask:** the expanded card names the model connection and whether web search is enabled. Sources are visible beside the answer. Copy, follow-up, and insert into a chosen editor are separate actions.

Text editing in the expanded card is intentional and may take focus. Collapsing it returns to the passive surface without changing a saved destination. Never add a permanent sidebar for the first release. Completion can be muted; spoken readback is optional. Keep agent approvals in the agent's own interface initially.

## Implementation boundaries

Retain the existing capture/recognition/cleanup pipeline. Add a `Destination` sum type for editor, agent session, or model conversation, captured into an immutable turn. A `TurnCoordinator` owns draft/review/delivery states separately from microphone state; `AgentAdapter`, `ModelProvider`, `SearchProvider`, and `ContextAttachment` keep transport details out of the HUD.

Use a local authenticated connection for agent adapters and bind local servers to loopback. Request IDs and acknowledgements support deduplication where the transport permits it. If a connection drops after dispatch without an acknowledgement, show uncertain delivery and inspect the session before retrying; do not promise exactly-once network delivery. Reconnecting never chooses a different session automatically.

Keep ordinary dictation offline. Only an explicit agent/Ask request and selected attachments can leave the local dictation pipeline, to the named destination. Keep API keys in Keychain and out of logs. Do not scan other chats, terminal history, or browser tabs in the background. Treat retrieved pages as reference data, not instructions that can change the destination or execute tools. Store unsent drafts locally with an explicit retention choice; history starts off by default.

## Release gates and differentiation test

First demonstrate: open two agent sessions; pin one; browse elsewhere; dictate a request; attach a selected excerpt; send to the pinned session; receive its reply; reconnect without losing the pending draft or duplicating an acknowledged request.

Block release on wrong-session delivery, silent context substitution, duplicate retry submission, or lost unsent text. Test sleeping/waking, agent restarts, busy sessions, revoked access, lost network, clipboard changes, and prompt-preservation cases with identifiers and negation. Keep the existing short-dictation latency gate, and report transport overhead separately from model response time.

Try the same research-to-agent tasks with five developers using this prototype and their current tools. Measure manual copy/paste steps, recovery actions, time to send the intended prompt, and preference for daily use. Record any wrong destination. Do not expand to more connectors until a repeated workflow advantage is visible. Open source, local dictation, and direct provider billing can support the positioning; dependable daily use must carry it.

Deferred: a general autonomous desktop agent, automatic shell execution, voice-only permission approvals, silent screen capture, all-provider support, cross-device sync, and a marketplace. They would broaden the product before the selected workflow has been proven.
