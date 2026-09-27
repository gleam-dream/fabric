# Captures BeamWeaver oracle fixtures for Fabric's slice 1 differential tests.
#
# Portions derived from BeamWeaver (https://github.com/caudena/beam_weaver,
# Apache-2.0), as of commit 60fdcd7 / fork d0aa1f9. The scenario shapes follow
# the transcript-pure scripted-model pattern of BeamWeaver's own tests
# (test/beam_weaver/agent/dsl_test.exs, human_in_the_loop_test.exs).
#
# Run from a scratch clone of the fork at the pinned commit, never from the
# fork itself (see docs/ORACLE.md):
#
#   PATH=<elixir-1.19.5>/bin:<erlang-28.5>/bin:$PATH MIX_ENV=test \
#     FIXTURE_DIR=<fabric>/test/oracle/fixtures \
#     mix run --no-compile <fabric>/test/oracle/capture/capture.exs
#
# Output: one normalized JSON fixture per scenario. Message ids, run ids,
# checkpoint ids, timestamps and provider metadata are not written.

alias BeamWeaver.Agent
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message
alias BeamWeaver.Core.Tool

defmodule Oracle.Effects do
  def start_link, do: Elixir.Agent.start_link(fn -> [] end, name: __MODULE__)
  def reset, do: Elixir.Agent.update(__MODULE__, fn _ -> [] end)
  def put(entry), do: Elixir.Agent.update(__MODULE__, &[entry | &1])
  def all, do: Elixir.Agent.get(__MODULE__, &Enum.reverse/1)
end

defmodule Oracle.Model do
  @moduledoc "Transcript-pure scripted model; `script` picks the scenario."
  @behaviour BeamWeaver.Core.ChatModel
  defstruct script: :two_calls

  @impl true
  def invoke(%__MODULE__{script: script}, messages, _opts) do
    tool_msgs = Enum.filter(messages, &match?(%Message{role: :tool}, &1))
    Oracle.Effects.put("model:tool_msgs=#{length(tool_msgs)}")
    {:ok, reply(script, tool_msgs)}
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
end

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
  "command" => "MIX_ENV=test FIXTURE_DIR=... mix run --no-compile test/oracle/capture/capture.exs",
  "captured" => Date.utc_today() |> Date.to_iso8601(),
  "license" => "Output of running BeamWeaver (Apache-2.0); not copied source."
}

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

  fixture =
    Map.merge(provenance, %{
      "scenario" => name,
      "description" => description,
      "result" => Oracle.Normalize.result(result),
      "effects" => Oracle.Effects.all()
    })

  path = Path.join(dir, name <> ".json")
  File.write!(path, [Jason.encode_to_iodata!(fixture, pretty: true), "\n"])
  IO.puts("wrote #{path}: #{inspect(Oracle.Normalize.result(result), limit: :infinity)}")
end
