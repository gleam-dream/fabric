# fabric_relay

MCP for Fabric over [Relay](https://github.com/gleam-dream/relay): remote
MCP tools in Fabric agents and graphs, and Fabric agents served as MCP
tools. Fabric itself does not depend on Relay.

## Call MCP tools from an agent

One Relay `Definition` serves the server and the client. `fabric_relay.tool`
makes it a Fabric tool: the model sees the definition's name, description
and input schema, and each call goes to the client the run's context names.

```gleam
import fabric/agent
import fabric/policy
import fabric_relay
import relay/client

pub type Context {
  Context(inventory: client.Client)
}

pub fn assistant(model) {
  let inventory = fn(context: Context) { context.inventory }
  agent.new(
    "assistant",
    model,
    [
      fabric_relay.tool(search_products(), peer: inventory),
      fabric_relay.tool(reserve_stock(), peer: inventory),
    ],
    policy.always_allow(),
  )
  |> agent.build
}
```

`fabric_relay.discover(connected, peer:)` mounts every tool a server lists
now, validating the model's arguments against each advertised schema;
`discovered(declaration, peer:)` mounts one. `operation(definition,
version:, peer:)` is the same call as a graph activity.

Every call carries the run's correlation, so the server's events join the
run's, and an idempotency key derived from the run and the action (for a
graph, the run and the activation), which stays the same when the action is
replayed or recovered.

| The call                                                     | The run                                                                     |
| ------------------------------------------------------------ | --------------------------------------------------------------------------- |
| succeeded                                                    | the model sees the structured output (a listed content-only tool: its text) |
| the tool answered `isError: true`                            | `Explain`: the model sees the text and the run goes on                      |
| the tool asked for client input                              | `Explain`: an agent cannot answer it                                        |
| nothing was sent, or the server answered with an error       | `Explain`                                                                   |
| the request may have reached the server (`client.MaybeSent`) | `Uncertain`: the run waits for a person; a read-only tool: `Explain`        |

The decision uses Relay's submission evidence (`client.evidence`) and the
server's `readOnlyHint`: a lost call to a tool that changes state is never
retried by the model.

## Serve an agent as an MCP tool

```gleam
import fabric_relay
import relay/server
import relay/tool as relay_tool

pub fn ask_assistant() -> relay_tool.Definition(Question, Answer) {
  relay_tool.define("ask_assistant", question_codec(), answer_codec())
}

pub fn mcp(runs, assistant) -> server.Server(Principal) {
  let service =
    fabric_relay.service(runs, assistant, start: fn(call, question: Question) {
      let principal = relay_tool.context(call)
      Ok(fabric_relay.start(
        context_for(principal),
        prompt: question.text,
        principal: principal.subject,
      ))
    })
  server.new([fabric_relay.serve(ask_assistant(), service)])
}
```

The agent's answer type is the definition's output
(`agent.with_answer(answer_codec())`), so a completed run answers with the
typed value. Each call's run takes the call's correlation
(`relay/tool.correlation`).

A call with an idempotency key (`client.with_idempotency_key`) names its
run: `fabric_relay.run_id(definition, principal:, key:)`. A retried call
with the same key reaches the same run and waits for it again, instead of
starting a second run; the key is scoped by the principal `start` names, so
one client cannot reach another's run. Such a run outlives its call: a
disconnect, or a wait that ends first, leaves it running for the retry. A
call without a key owns its run, which is cancelled when the call is
cancelled (an HTTP client disconnects) or its wait ends.

A run that does not complete in time answers `isError: true` with a line
for people and structured content: `error` (`working`, `timed_out`,
`awaiting_approval`, `outcome_unknown`, `unattended`, `cancelled`,
`key_reused`, `start_failed`, `unavailable`, or how the run ended, such as
`answer_invalid`) and `run_id`, with `approvals` or `uncertain` where they
apply. An application answers an approval on the run the id names
(`fabric.open`, `fabric.approve`), and the client's retry with the same key
gets the answer.

## Defaults

| Bound                         | Default                        | Change it with                                 |
| ----------------------------- | ------------------------------ | ---------------------------------------------- |
| A call's wait for the answer  | 25 s                           | `fabric_relay.with_wait`                       |
| A remote call                 | Relay's client: 30 s           | `client.with_timeout`, `client.with_deadline`  |
| A remote tool's body          | the agent's tool timeout: 60 s | `agent.with_tool_timeout`, `tool.with_timeout` |
| Retries of a lost remote call | none: `Uncertain`              | `tool.with_replay` for a safe tool             |

Keep the wait shorter than the Relay server's request and invocation
timeouts (30 s by default): when Relay ends the call first, a run the call
owns is cancelled.

## Development

The package needs the sibling checkouts `../relay`, `../json_blueprint` and
`../sinal` next to this repository. From the repository root:

```sh
nix develop -c sh -c 'cd integrations/fabric_relay && gleam build --warnings-as-errors && gleam test'
```

The tests run Relay servers in process and over HTTP. See
[CHANGELOG.md](CHANGELOG.md).
