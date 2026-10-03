//// An ordinary agent as a managed graph operation. The agent owns its
//// transcript, tools and approvals. The graph owns its child attachment.

import fabric
import fabric/agent as worker
import fabric/graph
import fabric/graph/child
import fabric/graph/operation
import fabric/internal/checked_agent
import fabric/internal/controller
import fabric/internal/family
import fabric/internal/graph/agent_child
import fabric/internal/graph/attachment
import fabric/internal/graph/child_driver
import fabric/internal/graph/handle as graph_handle
import fabric/internal/graph/managed
import fabric/internal/run_id
import fabric/internal/runner
import fabric/internal/store as store_core
import fabric/model
import fabric/run
import fabric/store
import fabric/store/backend
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec.{type Codec}
import sinal/correlation

/// Version this binding when its prompt, reply meaning or deployed agent
/// changes. Codecs describe native values, not provider output schemas.
/// Prompt and answer callbacks must be pure: recovery and observation may
/// call them again. Only the agent runner performs model and tool effects.
pub type Definition(context, input, output) {
  Definition(
    identity: run.DefinitionId,
    agent: worker.Agent(context),
    input: Codec(input),
    output: Codec(output),
    prompt: fn(input) -> String,
    answer: fn(String) -> Result(output, String),
  )
}

pub opaque type Runtime(context, input, output) {
  Runtime(
    definition: Definition(context, input, output),
    store: store.Store,
    context: fn() -> context,
  )
}

pub type ConfigurationError {
  ChildIdsTooLong(maximum: Int, limit: Int)
}

pub fn new(
  definition: Definition(context, input, output),
  runs: store.Store,
  context: fn() -> context,
) -> Result(Runtime(context, input, output), ConfigurationError) {
  let admitted = checked_agent.admitted(definition.agent)
  let maximum =
    string.length(attachment.reserved_id("parent", 1))
    + suffix_length(admitted, admitted.max_depth)
  case maximum <= 128 {
    True -> Ok(Runtime(definition, runs, context))
    False -> Error(ChildIdsTooLong(maximum, 128))
  }
}

fn suffix_length(
  agent: checked_agent.Admitted(context),
  remaining: Int,
) -> Int {
  let remaining = int.min(remaining, agent.max_depth)
  case
    remaining <= 0 || agent.max_children == 0 || dict.size(agent.children) == 0
  {
    True -> 0
    False ->
      1
      + string.length(int.to_string(agent.max_children))
      + list.fold(dict.values(agent.children), 0, fn(longest, child) {
        int.max(longest, suffix_length(child, remaining - 1))
      })
  }
}

/// Parent and child use the same supervised store. Context is rebuilt when
/// starting or recovering the child, rather than stored in the graph record.
pub fn as_operation(
  runtime: Runtime(context, input, output),
) -> operation.Operation(parent_context, input, output) {
  let runs = runtime.store
  let answer = runtime.definition.answer
  let output = runtime.definition.output
  managed.agent(
    runtime.definition.identity,
    runtime.definition.input,
    output,
    child_driver.Driver(
      store: fn() { store_core.pid(runs) },
      reserve: fn(parent, id, input, reservation) {
        reserve(runtime, parent, id, input, reservation, 3)
      },
      read: fn(parent, id, mode) {
        use progress <- result.map(agent_child.progress(runs, parent, id))
        case progress {
          child.Succeeded(text) if mode == child_driver.Observe ->
            case
              answer(text)
              |> result.try(fn(value) {
                codec.encode_json(output, value)
                |> result.map_error(string.inspect)
              })
            {
              Ok(encoded) -> child.Succeeded(encoded)
              Error(reason) -> child.InvalidOutput(text, reason)
            }
          other -> other
        }
      },
    ),
  )
}

pub type OpenError {
  DifferentStore
  Unreadable(fabric.Error)
  InvalidAttachment
}

/// Open a retained child, including a completed one. The store and reciprocal
/// attachment must match; use the returned ordinary handle for all agent APIs.
pub fn child(
  parent: graph.Handle(parent_context, state, answer),
  activation: Int,
  runtime: Runtime(context, input, output),
) -> Result(fabric.Run(context), OpenError) {
  use _ <- result.try(
    case
      store_core.pid(graph_handle.store(parent)),
      store_core.pid(runtime.store)
    {
      Ok(parent_store), Ok(child_store) if parent_store == child_store -> Ok(Nil)
      _, _ -> Error(DifferentStore)
    },
  )
  let parent = child.Parent(run.id_to_string(graph.id(parent)), activation)
  let id = attachment.reserved_id(parent.run, activation)
  use handle <- result.try(
    fabric.open(
      runtime.store,
      runtime.definition.agent,
      runtime.context(),
      run_id.from_string(id),
    )
    |> result.map_error(Unreadable),
  )
  use snapshot <- result.try(
    fabric.snapshot(handle) |> result.map_error(Unreadable),
  )
  case snapshot.parent == Some(attachment.parent(parent)) {
    True -> Ok(handle)
    False -> Error(InvalidAttachment)
  }
}

fn reserve(
  runtime: Runtime(context, input, output),
  parent: child.Parent,
  id: String,
  encoded: String,
  reservation: child_driver.Reservation,
  tries: Int,
) -> Result(Nil, String) {
  case reservation {
    child_driver.Cancel -> cancel(runtime, parent, id, tries)
    child_driver.Start -> start(runtime, parent, id, encoded, tries)
    child_driver.Discover -> {
      use _ <- result.try(
        runner.load(runtime.store, id) |> result.map_error(string.inspect),
      )
      start(runtime, parent, id, encoded, tries)
    }
  }
}

fn cancel(
  runtime: Runtime(context, input, output),
  parent: child.Parent,
  id: String,
  tries: Int,
) -> Result(Nil, String) {
  case runner.load(runtime.store, id) {
    Ok(#(_, state)) -> {
      use _ <- result.try(agent_child.check(state, parent))
      case controller.child_result(state) {
        Ok(_) -> Ok(Nil)
        Error(_) ->
          runner.cancel_unattended(
            runtime.store,
            id,
            checked_agent.admitted(runtime.definition.agent).command_timeout,
            tries,
          )
          |> result.replace(Nil)
          |> result.map_error(string.inspect)
      }
    }
    Error(runner.NotFound) -> {
      let agent = checked_agent.admitted(runtime.definition.agent)
      let tombstone =
        controller.State(
          run: id,
          agent: agent.identity,
          incarnation: 1,
          parent: Some(attachment.parent(parent)),
          depth: 0,
          limits: controller.Limits(
            agent.max_turns,
            agent.token_budget,
            agent.max_children,
            agent.max_depth,
          ),
          turns_used: 0,
          usage: run.TokenUsage(0, 0, 0),
          transcript: [],
          history: [],
          approvals_issued: 0,
          phase: controller.NeverStarted,
          family_budget: None,
          correlation: correlation.from_key(id),
          root: id,
        )
      use encoded <- result.try(
        store_core.encode(runtime.store, tombstone)
        |> result.map_error(string.inspect),
      )
      case
        store_core.insert(
          runtime.store,
          id,
          encoded,
          store_core.Detached(False, False),
        )
      {
        Ok(_) -> Ok(Nil)
        Error(backend.AlreadyExists) if tries > 1 ->
          cancel(runtime, parent, id, tries - 1)
        Error(error) -> Error(string.inspect(error))
      }
    }
    Error(error) -> Error(string.inspect(error))
  }
}

fn start(
  runtime: Runtime(context, input, output),
  parent: child.Parent,
  id: String,
  encoded: String,
  tries: Int,
) -> Result(Nil, String) {
  let definition = runtime.definition
  let setup =
    runner.setup(
      runtime.store,
      checked_agent.admitted(definition.agent),
      runtime.context(),
      None,
    )
  use input <- result.try(
    codec.decode_json(definition.input, encoded)
    |> result.map_error(string.inspect),
  )
  let prompt = definition.prompt(input)
  case runner.load_checked(setup, id) {
    Ok(#(_, state)) -> {
      use _ <- result.try(agent_child.check(state, parent))
      use _ <- result.try(case state.phase, state.transcript {
        controller.NeverStarted, [] -> Ok(Nil)
        _, [model.UserMessage(saved), ..] if saved == prompt -> Ok(Nil)
        _, _ -> Error("agent prompt differs from its reserved input")
      })
      case controller.child_result(state) {
        Ok(_) -> Ok(Nil)
        Error(_) ->
          family.take_over(setup, id, 3) |> result.map_error(string.inspect)
      }
    }
    Error(runner.NotFound) -> {
      let #(initial, effects) =
        runner.root_state(setup, id, prompt, correlation.from_key(id))
      let initial =
        controller.State(..initial, parent: Some(attachment.parent(parent)))
      use _ <- result.try(
        case runner.ancestors_open(runtime.store, id, initial.parent) {
          True -> Ok(Nil)
          False -> Error("parent no longer accepts child work")
        },
      )
      case runner.launch_new(setup, initial, effects) {
        Ok(_) -> Ok(Nil)
        Error(backend.AlreadyExists) if tries > 1 ->
          start(runtime, parent, id, encoded, tries - 1)
        Error(error) -> Error(string.inspect(error))
      }
    }
    Error(error) -> Error(string.inspect(error))
  }
}
