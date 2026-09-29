# Frozen version-2 reader

Source: Fabric commit `570502e928496b0203909f164a5e8fd021b8ddc8`, immediately before
`ce16091` introduced record version 3. The decoder in `record.gleam` is the
complete historical `decode` function and its helpers, up to the
compatibility-check section. Decoder bodies are unchanged. Only module
imports are redirected to the historical type declarations in this folder;
unused encoder/check imports are omitted. Those declarations are copied
from the same revision (controller, model, policy and run).

This is a test fixture, not another production codec. It deliberately
retains the old budget type, string run ids, and empty-transcript tombstone
representation. Tests require this reader to accept version-2 output and
reject version 3. Do not replace its parsing logic or types with current
ones when the runtime changes.
