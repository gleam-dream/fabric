# Build graph runtimes in each graph runner

Status: needs-triage
Category: enhancement

## What

A graph runner now receives its work once, in its first message, but the
runtime is built once by the application and copied whole into every graph
runner, with its operations and codecs, and again into the process of each
bounded callback, whose closure reads the runner's work. An agent node made
with `agent.build_with` keeps its agent as a builder, but
`graph/agent.as_operation` embeds the built answer codec in the operation.
Each compiled node also holds its codecs once per callback that uses them
(invoke, accept, check output), and an LLM decision's receipt codec holds
its output codec once per callback of a custom codec. Measured for a graph
of one LLM decision (`graph/llm.decision`): the runtime is 16.5 kB with a
boolean output and 112.7 kB with a 3.2 kB nested output, so what crosses
into the graph runner holds the output codec about 32 times. The receipt's
own fields (`receipt_fields`) are built inside the receipt codec's
callbacks, per encode or decode, and do not cross; their member order is a
stored format.

A graph builder like the agent builder (`graph.build_with`), or one
dispatching callback per compiled node, would remove these copies. The
design layer records it as a pending build entry.

## Acceptance

- `an_llm_decision_crosses_with_its_output_codec_a_fixed_number_of_times_test`
  (`test/fabric/graph_llm_test.gleam`) bounds the growth today at 36 times
  the output codec; the change lowers that bound to a few times.
