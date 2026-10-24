# Captures BeamWeaver oracle fixtures for Fabric's differential tests.
#
# Portions derived from BeamWeaver (https://github.com/caudena/beam_weaver,
# Apache-2.0), as of commit 60fdcd7 / fork d0aa1f9. The scenario shapes follow
# the transcript-pure scripted-model pattern of BeamWeaver's own tests
# (test/beam_weaver/agent/dsl_test.exs, human_in_the_loop_test.exs), the
# sub-agent gate scenarios follow the `task` tool of
# lib/beam_weaver/agent/middleware/subagents.ex with `interrupt_on`, and the
# cold-restart scenario follows the separate-VM pattern of
# test/beam_weaver/graph/cold_replay_test.exs.
#
# Run from a scratch clone of the fork at the pinned commit, never from the
# fork itself (see docs/ORACLE.md). The exact command is recorded in every
# fixture's "command" field; <scratch clone> is the clone and <fabric> is the
# Fabric repository root:
#
#   cd <scratch clone> && PATH=/nix/store/5fbjxaaizi26pmghbyn09llww48qg01q-elixir-1.19.5/bin:/nix/store/cyr4xsis8csd0sjvmy6lxaw9214f1sjf-erlang-28.5/bin:$PATH \
#     MIX_ENV=test FIXTURE_DIR=<fabric>/test/oracle/fixtures \
#     mix run --no-compile <fabric>/test/oracle/capture/capture.exs < /dev/null
#
# The hitl_cold_restart scenario starts two further `mix run` VMs of this same
# script (argument `cold_vm`), one after the other, sharing a temporary SQLite
# checkpoint database and a file-backed effect log.
#
# Output: one normalized JSON fixture per scenario. Message ids, run ids,
# checkpoint ids, timestamps, provider metadata and literal interrupt ids are
# not written.

alias BeamWeaver.Agent
alias BeamWeaver.Agent.Subagent
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message
alias BeamWeaver.Core.Tool

# The fork's SQLite test repo, used by the cold-restart VMs (cwd is the clone).
Code.require_file(Path.expand("support/live_sqlite.exs", File.cwd!()))

defmodule Oracle.Effects do
  @moduledoc "Effect ledger; with a file, entries are also appended to it so they survive a VM exit."
  def start_link(file \\ nil),
    do: Elixir.Agent.start_link(fn -> %{file: file, entries: []} end, name: __MODULE__)

  def reset, do: Elixir.Agent.update(__MODULE__, &%{&1 | entries: []})

  def put(entry) do
    Elixir.Agent.update(__MODULE__, fn %{file: file, entries: entries} = s ->
      if file, do: File.write!(file, entry <> "\n", [:append])
      %{s | entries: [entry | entries]}
    end)
  end

  def all, do: Elixir.Agent.get(__MODULE__, &Enum.reverse(&1.entries))

  def read_file(file),
    do: if(File.exists?(file), do: file |> File.read!() |> String.split("\n", trim: true), else: [])
end

defmodule Oracle.Model do
  @moduledoc "Transcript-pure scripted model; `script` picks the scenario."
  @behaviour BeamWeaver.Core.ChatModel
  defstruct script: :two_calls

  @impl true
  def invoke(%__MODULE__{script: :subagent}, messages, _opts) do
    # Parent and child share this model; the first user message tells them
    # apart ("go" for the parent, the task description for the child).
    who =
      Enum.find_value(messages, fn
        %Message{role: :user, content: content} -> to_string(content)
        _ -> nil
      end)

    tool_msgs = Enum.filter(messages, &match?(%Message{role: :tool}, &1))
    Oracle.Effects.put("model:#{who}:tool_msgs=#{length(tool_msgs)}")
    {:ok, subagent_reply(who, tool_msgs)}
  end

  def invoke(%__MODULE__{script: script}, messages, _opts) do
    tool_msgs = Enum.filter(messages, &match?(%Message{role: :tool}, &1))
    Oracle.Effects.put("model:tool_msgs=#{length(tool_msgs)}")
    {:ok, reply(script, tool_msgs)}
  end

  defp subagent_reply("go", []) do
    Message.assistant("",
      tool_calls: [
        %{id: "call_task", name: "task", args: %{"subagent_type" => "researcher", "description" => "Paris"}}
      ]
    )
  end

  defp subagent_reply("Paris", []) do
    Message.assistant("", tool_calls: [%{id: "call_c", name: "lookup", args: %{"city" => "Paris"}}])
  end

  defp subagent_reply(_who, msgs) do
    Message.assistant("final: " <> Enum.map_join(msgs, "|", &to_string(&1.content)))
  end

  defp reply(:two_calls, []) do
    Message.assistant("",
      tool_calls: [
        %{id: "call_a", name: "lookup", args: %{"city" => "Paris"}},
        %{id: "call_b", name: "pay", args: %{"to" => "bob"}}
      ]
    )
  end

  defp reply(:tool_error, []) do
    Message.assistant("",
      tool_calls: [
        %{id: "call_a", name: "lookup", args: %{"city" => "Paris"}},
        %{id: "call_b", name: "lookup", args: %{"city" => "Oslo"}},
        %{id: "call_c", name: "ghost", args: %{}}
      ]
    )
  end

  defp reply(:loop, msgs) do
    n = length(msgs) + 1
    Message.assistant("", tool_calls: [%{id: "call_#{n}", name: "step", args: %{"n" => n}}])
  end

  defp reply(:hitl, []) do
    Message.assistant("", tool_calls: [%{id: "call_t", name: "pay", args: %{"to" => "bob"}}])
  end

  defp reply(_script, msgs) do
    Message.assistant("final: " <> Enum.map_join(msgs, "|", &to_string(&1.content)))
  end
end

defmodule Oracle.Tools do
  defp schema(field),
    do: %{"type" => "object", "properties" => %{field => %{"type" => "string"}}, "required" => [field]}

  def lookup do
    Tool.from_function!(
      name: "lookup",
      description: "Weather lookup",
      input_schema: schema("city"),
      handler: fn input, _opts ->
        city = input["city"] || input[:city]
        Oracle.Effects.put("tool:lookup:#{city}")
        case city do
          "Paris" -> "sunny in Paris"
          other -> {:error, "unknown city: #{other}"}
        end
      end
    )
  end

  def pay do
    Tool.from_function!(
      name: "pay",
      description: "Payment",
      input_schema: schema("to"),
      handler: fn input, _opts ->
        to = input["to"] || input[:to]
        Oracle.Effects.put("tool:pay:#{to}")
        "paid #{to}"
      end
    )
  end

  def step do
    Tool.from_function!(
      name: "step",
      description: "One step",
      input_schema: %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}, "required" => ["n"]},
      handler: fn input, _opts ->
        n = input["n"] || input[:n]
        Oracle.Effects.put("tool:step:#{n}")
        "stepped #{n}"
      end
    )
  end
end

defmodule Oracle.Normalize do
  def transcript(messages), do: Enum.map(messages, &message/1)

  defp message(%Message{role: :assistant, tool_calls: calls}) when is_list(calls) and calls != [] do
    %{"role" => "assistant_calls", "calls" => Enum.map(calls, &%{"name" => &1.name, "id" => &1.id})}
  end

  defp message(%Message{role: :tool} = m) do
    %{
      "role" => "tool",
      "id" => m.tool_call_id,
      "status" => to_string(Map.get(m, :status) || get_in(m.metadata || %{}, [:status]) || "success"),
      "content" => to_string(m.content)
    }
  end

  defp message(%Message{role: role, content: content}),
    do: %{"role" => to_string(role), "content" => to_string(content)}

  def result({:ok, %{messages: msgs}}), do: %{"tag" => "ok", "transcript" => transcript(msgs)}

  def result({:error, error}),
    do: %{"tag" => "error", "type" => to_string(Map.get(error, :type)), "message" => Map.get(error, :message)}

  def result({:interrupted, _}), do: %{"tag" => "interrupted"}

  @doc """
  An interrupted HITL result with its review request and the paused state.
  The literal interrupt id is replaced by whether it equals the id the
  paused snapshot reports; the call ids under review are read from the
  pending assistant message, since the action requests carry no call id.
  """
  def paused({:interrupted, interrupt}, {:ok, snapshot}) do
    msgs = snapshot_messages(snapshot)
    value = interrupt.value
    requests = Map.get(value, :action_requests, [])

    pending_calls =
      msgs
      |> Enum.reverse()
      |> Enum.find_value([], fn
        %Message{role: :assistant, tool_calls: calls} when is_list(calls) -> calls
        _ -> nil
      end)

    under_review =
      requests
      |> Enum.map(fn request -> Enum.find(pending_calls, &(&1.name == request.name)) end)
      |> Enum.map(&%{"name" => &1.name, "id" => &1.id})

    %{
      "tag" => "interrupted",
      "interrupt" => %{
        "nodes" => Enum.map(interrupt.nodes, &to_string/1),
        "timing" => to_string(interrupt.timing),
        "action_requests" =>
          Enum.map(requests, &%{"name" => &1.name, "args" => &1.args, "description" => &1.description}),
        "review_configs" =>
          Enum.map(
            Map.get(value, :review_configs, []),
            &%{"action_name" => &1.action_name, "allowed_decisions" => &1.allowed_decisions}
          ),
        "under_review" => under_review,
        "id_matches_snapshot" => Enum.map(snapshot.interrupts, & &1.id) == [interrupt.id]
      },
      "snapshot" => snapshot(snapshot)
    }
  end

  def snapshot(snapshot) do
    %{
      "next" => Enum.map(snapshot.next, &to_string/1),
      "interrupts" => length(snapshot.interrupts),
      "transcript" => transcript(snapshot_messages(snapshot))
    }
  end

  defp snapshot_messages(snapshot),
    do: Map.get(snapshot.values, :messages) || Map.get(snapshot.values, "messages") || []
end

defmodule Oracle.Hitl do
  @moduledoc "The reviewed-payment agent shared by the HITL scenarios."
  def build(name, checkpointer) do
    {:ok, agent} =
      Agent.build(
        name: name,
        model: struct(Oracle.Model, script: :hitl),
        tools: [Oracle.Tools.pay()],
        interrupt_on: %{"pay" => true},
        checkpointer: checkpointer
      )

    agent
  end

  def config(thread), do: %{"configurable" => %{"thread_id" => thread}}
  def input, do: %{messages: [Message.user("go")]}
end

defmodule Oracle.Delegation do
  @moduledoc "A parent whose sub-agent start (the `task` tool) needs a review."
  def build(name) do
    researcher =
      Subagent.Spec.new(
        name: "researcher",
        description: "Researches a city",
        system_prompt: "You research cities.",
        tools: [Oracle.Tools.lookup()],
        interrupt_on: nil
      )

    {:ok, agent} =
      Agent.build(
        name: name,
        model: struct(Oracle.Model, script: :subagent),
        tools: [],
        subagents: [researcher],
        interrupt_on: %{"task" => true},
        checkpointer: CheckpointETS.new()
      )

    agent
  end
end

defmodule Oracle.ColdVM do
  @moduledoc """
  One half of hitl_cold_restart, run in its own `mix run` VM. Every
  :beam_weaver module is loaded first: the JSON checkpoint decoder uses
  String.to_existing_atom, and a fresh VM otherwise fails the read with
  :checkpoint_read_failed ("atom is not loaded in the current VM").
  """
  alias BeamWeaver.Checkpoint.Ecto, as: CheckpointEcto
  alias BeamWeaver.Test.SQLiteRepo

  @thread "hitl_cold_restart"
  @decision %{"decisions" => [%{"type" => "approve"}]}

  def decision, do: @decision

  def run(mode, database, log, out) do
    {:ok, mods} = :application.get_key(:beam_weaver, :modules)
    Enum.each(mods, &Code.ensure_loaded/1)
    {:ok, _} = Oracle.Effects.start_link(log)

    Application.put_env(:beam_weaver, SQLiteRepo, database: database, pool_size: 1)
    {:ok, repo} = SQLiteRepo.start_link()
    Process.unlink(repo)

    if mode == "produce" do
      :persistent_term.put({BeamWeaver.Test.LiveSQLiteMigration, :opts},
        adapters: [{:checkpoint, checkpoints_table: "oracle_cp", writes_table: "oracle_cpw"}]
      )

      :ok = Ecto.Migrator.up(SQLiteRepo, 89_000_000_000_901, BeamWeaver.Test.LiveSQLiteMigration)
      :persistent_term.erase({BeamWeaver.Test.LiveSQLiteMigration, :opts})
    end

    saver = CheckpointEcto.new(repo: SQLiteRepo, checkpoints_table: "oracle_cp", writes_table: "oracle_cpw")
    agent = Oracle.Hitl.build("oracle_hitl_cold_restart", saver)
    config = Oracle.Hitl.config(@thread)

    step =
      case mode do
        "produce" ->
          result = Agent.invoke(agent, Oracle.Hitl.input(), config: config)
          Map.put(Oracle.Normalize.paused(result, Agent.get_state(agent, config: config)), "call", "invoke")

        "resume" ->
          {:ok, before} = Agent.get_state(agent, config: config)
          result = Agent.resume(agent, @decision, config: config)
          {:ok, after_resume} = Agent.get_state(agent, config: config)

          %{
            "call" => "resume",
            "decision" => @decision,
            "snapshot_before" => Oracle.Normalize.snapshot(before),
            "result" => Oracle.Normalize.result(result),
            "snapshot_after" => Oracle.Normalize.snapshot(after_resume)
          }
      end

    File.write!(out, Jason.encode_to_iodata!(Map.put(step, "effects", Oracle.Effects.all())))
    Supervisor.stop(SQLiteRepo)
  end
end

case Enum.reject(System.argv(), &(&1 == "--")) do
  ["cold_vm", mode, database, log, out] ->
    Oracle.ColdVM.run(mode, database, log, out)

  [] ->
    {:ok, _} = Oracle.Effects.start_link()
    dir = System.fetch_env!("FIXTURE_DIR")
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    provenance = %{
      "oracle" => %{
        "repository" => "lostbean/beam_weaver (fork of caudena/beam_weaver)",
        "commit" => String.trim(commit),
        "elixir" => System.version(),
        "otp" => System.otp_release()
      },
      "script" => "test/oracle/capture/capture.exs",
      "command" =>
        "cd <scratch clone> && PATH=/nix/store/5fbjxaaizi26pmghbyn09llww48qg01q-elixir-1.19.5/bin:" <>
          "/nix/store/cyr4xsis8csd0sjvmy6lxaw9214f1sjf-erlang-28.5/bin:$PATH MIX_ENV=test " <>
          "FIXTURE_DIR=<fabric>/test/oracle/fixtures mix run --no-compile " <>
          "<fabric>/test/oracle/capture/capture.exs < /dev/null",
      "captured" => Date.utc_today() |> Date.to_iso8601(),
      "license" => "Output of running BeamWeaver (Apache-2.0); not copied source."
    }

    write = fn name, fixture ->
      path = Path.join(dir, name <> ".json")
      File.write!(path, [Jason.encode_to_iodata!(Map.merge(provenance, fixture), pretty: true), "\n"])
      path
    end

    scenarios = [
      {"two_tool_calls", "Two tool calls with distinct ids are executed and fed back in call order.",
       :two_calls, [Oracle.Tools.lookup(), Oracle.Tools.pay()], []},
      {"tool_error_visible",
       "A failing tool and an unknown tool become error tool messages; the run continues to a final answer.",
       :tool_error, [Oracle.Tools.lookup()], []},
      {"model_call_limit",
       "A model that always requests a tool is stopped by a run model-call limit of 2.",
       :loop, [Oracle.Tools.step()],
       [middleware: [BeamWeaver.Agent.Middleware.ModelCallLimit.new(run_limit: 2, thread_limit: nil, exit_behavior: :end)]]}
    ]

    for {name, description, script, tools, extra} <- scenarios do
      Oracle.Effects.reset()

      {:ok, agent} =
        Agent.build(
          Keyword.merge(
            [name: "oracle_#{name}", model: struct(Oracle.Model, script: script), tools: tools,
             checkpointer: CheckpointETS.new()],
            extra
          )
        )

      result = Agent.invoke(agent, %{messages: [Message.user("go")]}, config: %{"configurable" => %{"thread_id" => name}})

      path =
        write.(name, %{
          "scenario" => name,
          "description" => description,
          "result" => Oracle.Normalize.result(result),
          "effects" => Oracle.Effects.all()
        })

      IO.puts("wrote #{path}: #{inspect(Oracle.Normalize.result(result), limit: :infinity)}")
    end

    # HITL in one VM (ETS checkpointer): invoke pauses before `pay`, then one
    # resume answers the review.
    hitl = [
      {"hitl_approve",
       "The pay tool requires approval: invoke pauses before it runs; an approve decision runs it once and the model answers.",
       %{"decisions" => [%{"type" => "approve"}]}},
      {"hitl_reject",
       "The pay tool requires approval: invoke pauses before it runs; a reject decision with a message answers the call with an error tool message and pay never runs.",
       %{"decisions" => [%{"type" => "reject", "message" => "payment declined by reviewer"}]}}
    ]

    for {name, description, decision} <- hitl do
      Oracle.Effects.reset()
      agent = Oracle.Hitl.build("oracle_#{name}", CheckpointETS.new())
      config = Oracle.Hitl.config(name)

      invoked = Agent.invoke(agent, Oracle.Hitl.input(), config: config)
      pause = Oracle.Normalize.paused(invoked, Agent.get_state(agent, config: config))
      invoke_effects = Oracle.Effects.all()

      resumed = Agent.resume(agent, decision, config: config)
      all_effects = Oracle.Effects.all()

      path =
        write.(name, %{
          "scenario" => name,
          "description" => description,
          "steps" => [
            Map.merge(pause, %{"call" => "invoke", "effects" => invoke_effects}),
            %{
              "call" => "resume",
              "decision" => decision,
              "result" => Oracle.Normalize.result(resumed),
              "effects" => Enum.drop(all_effects, length(invoke_effects))
            }
          ],
          "result" => Oracle.Normalize.result(resumed),
          "effects" => all_effects
        })

      IO.puts("wrote #{path}: #{inspect(Oracle.Normalize.result(resumed), limit: :infinity)}")
    end

    # The sub-agent gate in one VM (ETS checkpointer): invoke pauses before
    # the `task` tool starts the child; approve runs the child once, reject
    # never starts it.
    delegation = [
      {"subagent_gate_approve",
       "Starting the researcher sub-agent (the task tool) requires approval: invoke pauses before the child exists; approve runs the child (its model and its lookup) once and its answer is the task result.",
       %{"decisions" => [%{"type" => "approve"}]}},
      {"subagent_gate_reject",
       "Starting the researcher sub-agent requires approval; a reject decision answers the task call with an error tool message and the child never runs.",
       %{"decisions" => [%{"type" => "reject", "message" => "no sub-agent today"}]}}
    ]

    for {name, description, decision} <- delegation do
      Oracle.Effects.reset()
      agent = Oracle.Delegation.build("oracle_#{name}")
      config = Oracle.Hitl.config(name)

      invoked = Agent.invoke(agent, Oracle.Hitl.input(), config: config)
      pause = Oracle.Normalize.paused(invoked, Agent.get_state(agent, config: config))
      invoke_effects = Oracle.Effects.all()

      resumed = Agent.resume(agent, decision, config: config)
      all_effects = Oracle.Effects.all()

      path =
        write.(name, %{
          "scenario" => name,
          "description" => description,
          "steps" => [
            Map.merge(pause, %{"call" => "invoke", "effects" => invoke_effects}),
            %{
              "call" => "resume",
              "decision" => decision,
              "result" => Oracle.Normalize.result(resumed),
              "effects" => Enum.drop(all_effects, length(invoke_effects))
            }
          ],
          "result" => Oracle.Normalize.result(resumed),
          "effects" => all_effects
        })

      IO.puts("wrote #{path}: #{inspect(Oracle.Normalize.result(resumed), limit: :infinity)}")
    end

    # HITL across a VM restart (A13): VM 1 invokes until the pause on an Ecto
    # SQLite checkpointer and exits; VM 2 resumes with approve.
    root = Path.join(System.tmp_dir!(), "fabric_oracle_cold_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    database = Path.join(root, "checkpoint.sqlite3")
    log = Path.join(root, "effects.log")
    script = __ENV__.file

    vm = fn mode ->
      out = Path.join(root, mode <> ".json")
      {output, status} =
        System.cmd("mix", ["run", "--no-compile", script, "--", "cold_vm", mode, database, log, out],
          env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

      if status != 0, do: raise("cold VM #{mode} exited #{status}:\n#{output}")
      out |> File.read!() |> Jason.decode!()
    end

    vm1 = vm.("produce")
    vm2 = vm.("resume")
    effects = Oracle.Effects.read_file(log)
    File.rm_rf!(root)

    name = "hitl_cold_restart"

    path =
      write.(name, %{
        "scenario" => name,
        "description" =>
          "The pay tool requires approval. VM 1 invokes until the pause with an Ecto SQLite checkpointer and exits; " <>
            "a fresh VM 2 resumes with approve, runs pay once, and the model answers.",
        "vm_setup" =>
          "Each VM is a separate `mix run --no-compile` of this script sharing one SQLite file; " <>
            "every :beam_weaver module is loaded first because the JSON checkpoint decoder uses String.to_existing_atom.",
        "steps" => [Map.put(vm1, "vm", 1), Map.put(vm2, "vm", 2)],
        "result" => vm2["result"],
        "effects" => effects
      })

    IO.puts("wrote #{path}: #{inspect(vm2["result"], limit: :infinity)}")
end
