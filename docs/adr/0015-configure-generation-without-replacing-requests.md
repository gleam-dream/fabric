# Configure generation without replacing requests

<a id="adr-0015"></a>

## Decision

On 16 October 2026 the owner approved configured_model with LLM Wire's immutable
generation settings. The existing constructor retains default behavior. Fabric
keeps transcript, replay, tool and answer assembly. The application owns live
model settings and reapplies them when reconstructing the runtime.

## Rationale and alternatives

Previously, applications needing output-token limits, sampling or cache references
had to rebuild the model adapter. A raw request callback would also permit changes
to messages and answer decoding. A settings value preserves the useful choices
without weakening those boundaries or duplicating provider controls in Fabric.

## Persistence and publication

Settings introduce no persisted fields or record version. Applications decide how
configuration remains stable across deployments. Unpublished coordinated changes
reach this repository once the sibling's change is on `main` and `gleam update
<package>` has re-locked it.
