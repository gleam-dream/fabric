//// A sub-agent record written before roots were stored names only its
//// parent. Its exact root is derived from the stored ancestors when it is
//// read, and its next commit stores it. The fixtures are a three-level
//// family (`legacy` → `legacy-1` → `legacy-1-1`) stored before wave 5,
//// with the grandchild waiting for two approvals.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/ancestry
import fabric/internal/controller
import fabric/internal/graph/record as graph_record
import fabric/internal/graph/runner as graph_runner
import fabric/internal/record
import fabric/internal/runner
import fabric/internal/store as store_core
import fabric/policy
import fabric/run.{Requirement}
import fabric/store
import fabric/support
import fabric/support/apps
import fabric/support/codecs
import fabric/support/restart
import fabric/support/scripted
import fabric/telemetry as o
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal

const root = "legacy"

const child = "legacy-1"

const grandchild = "legacy-1-1"

// --- the family the fixtures were written by -----------------------------------

fn research() -> tool.Definition(String, String) {
  tool.define(
    "research",
    "Research a topic.",
    codecs.one_field("topic", codec.string()),
    codec.string(),
  )
}

fn delegating(name: String, below: Agent(Nil, String)) -> Agent(Nil, String) {
  agent.new(
    name,
    scripted.plan([scripted.call("r1", "research", "{\"topic\":\"x\"}")]),
    [],
    policy.always_allow(),
  )
  |> agent.with_max_depth(2)
  |> agent.with_sub_agent(research(), to: below, prompt: fn(topic) { topic })
  |> support.agent
}

/// The leaf pays twice, and a person approves each payment.
fn leaf() -> Agent(Nil, String) {
  agent.new(
    "leaf",
    scripted.plan([
      scripted.call("t1", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}"),
      scripted.call("t2", "transfer_funds", "{\"to\":\"ann\",\"amount\":20}"),
    ]),
    [apps.transfer_tool()],
    fn(_, action: policy.Action) {
      case action.name {
        "transfer_funds" ->
          Ok(policy.RequireApproval(Requirement("transfer", 1)))
        _ -> Ok(policy.Allow)
      }
    },
  )
  |> support.agent
}

fn family() -> Agent(Nil, String) {
  delegating("front", delegating("middle", leaf()))
}

// --- fixtures ------------------------------------------------------------------

fn fixture(id: String) -> String {
  let assert Ok(text) =
    restart.read_file(
      "test/fixtures/records/pre-wave-5-family/" <> id <> ".json",
    )
  text
}

/// A started directory store over `dir` holding `records`.
fn stored(dir: String, records: List(#(String, String))) -> store.Store {
  let runs = support.directory(dir)
  list.each(records, fn(entry) {
    let assert Ok(_) =
      store_core.insert(
        runs,
        entry.0,
        entry.1,
        store_core.Detached(in_flight: False, seize: False),
      )
  })
  runs
}

fn fixtures(ids: List(String)) -> List(#(String, String)) {
  list.map(ids, fn(id) { #(id, fixture(id)) })
}

fn raw(runs: store.Store, id: String) -> String {
  let assert Ok(entry) = store_core.get(runs, id)
  entry.record
}

// --- events --------------------------------------------------------------------

/// Observes the events that name a run and its root, as
/// `#(event, run, root)`, and every `root_inferred`.
fn observe(seen: Subject(#(String, String, String))) -> List(sinal.Attachment) {
  [
    sinal.observe(o.approval_answered(), fn(_, m: o.ApprovalAnswered) {
      process.send(seen, #("approval_answered", m.action.run, m.root))
    }),
    sinal.observe(o.tool_settled(), fn(_, m: o.ToolSettled) {
      process.send(seen, #("tool_settled", m.action.run, m.root))
    }),
    sinal.observe(o.model_turn(), fn(_, m: o.ModelTurn) {
      process.send(seen, #("model_turn", m.run, m.root))
    }),
    sinal.observe(o.run_finished(), fn(_, m: o.RunFinished) {
      process.send(seen, #("run_finished", m.run, m.root))
    }),
    sinal.observe(o.root_inferred(), fn(_, m: o.RootInferred) {
      process.send(seen, #("root_inferred", m.run, m.root))
    }),
  ]
}

fn detach(attachments: List(sinal.Attachment)) -> Nil {
  list.each(attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
}

fn collect(seen: Subject(a), acc: List(a)) -> List(a) {
  case process.receive(seen, 100) {
    Ok(event) -> collect(seen, [event, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn of_family(
  events: List(#(String, String, String)),
) -> List(#(String, String, String)) {
  list.filter(events, fn(event) {
    event.1 == root || event.1 == child || event.1 == grandchild
  })
}

fn names(events: List(#(String, String, String)), run: String) -> List(String) {
  list.filter_map(events, fn(event) {
    case event.1 == run {
      True -> Ok(event.0)
      False -> Error(Nil)
    }
  })
}

// --- tests ---------------------------------------------------------------------

/// The grandchild's record names only its parent, which names only the
/// root. Its events carry the true root before its record stores it, and
/// after: its first commit writes the root back, and a later reader takes
/// it from the record.
pub fn a_pre_wave_5_grandchild_carries_its_true_root_test() {
  let dir = restart.temp_dir()
  let a = stored(dir, fixtures([root, child, grandchild]))
  string.contains(raw(a, grandchild), "\"root\"") |> should.be_false
  string.contains(raw(a, child), "\"root\"") |> should.be_false
  // A plain decode reads the parent, not exactly; a read of the store
  // derives the root from the ancestors.
  let assert Ok(decoded) = record.decode(raw(a, grandchild))
  #(decoded.root, decoded.root_exact) |> should.equal(#(child, False))
  let assert Ok(#(_, state)) = runner.load(a, grandchild)
  #(state.root, state.root_exact) |> should.equal(#(root, True))
  let assert Ok(#(_, state)) = runner.load(a, child)
  #(state.root, state.root_exact) |> should.equal(#(root, True))

  // Before the write-back: the first approval is the grandchild's first
  // commit.
  let seen = process.new_subject()
  let attachments = observe(seen)
  let assert Ok(handle) = fabric.open(a, family(), Nil, support.id(root))
  let assert Ok(run.Suspended([first, _], [])) =
    fabric.await(handle, within: duration.seconds(5))
  first.reference.run |> should.equal(support.id(grandchild))
  let assert Ok(_) =
    fabric.approve(
      handle,
      first.reference,
      proof: support.proof(
        first.reference.requirement,
        support.reviewer("alice"),
      ),
      context: Nil,
    )
  let assert Ok(run.Suspended([second], [])) =
    fabric.await(handle, within: duration.seconds(5))
  let before = of_family(collect(seen, []))
  names(before, grandchild)
  |> should.equal(["approval_answered", "tool_settled"])
  list.all(before, fn(event) { event.2 == root }) |> should.be_true

  // The write-back: the grandchild's record stores its root, and a plain
  // decode reads it exactly.
  string.contains(raw(a, grandchild), "\"root\":\"legacy\"") |> should.be_true
  let assert Ok(decoded) = record.decode(raw(a, grandchild))
  #(decoded.root, decoded.root_exact) |> should.equal(#(root, True))

  // After the write-back: another store reads the stored root.
  let assert Ok(Nil) = store.stop(a)
  let b = support.directory(dir)
  let assert Ok(handle) = fabric.open(b, family(), Nil, support.id(root))
  let assert Ok(_) =
    fabric.approve(
      handle,
      second.reference,
      proof: support.proof(
        second.reference.requirement,
        support.reviewer("alice"),
      ),
      context: Nil,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(handle, within: duration.seconds(5))
  let after = of_family(collect(seen, []))
  detach(attachments)
  names(after, grandchild)
  |> should.equal([
    "approval_answered", "tool_settled", "model_turn", "run_finished",
  ])
  list.count(after, fn(event) { event.0 == "run_finished" })
  |> should.equal(3)
  list.all(after, fn(event) { event.2 == root }) |> should.be_true
  list.any(list.append(before, after), fn(event) { event.0 == "root_inferred" })
  |> should.be_false
  restart.remove_dir(dir)
}

/// With the root's record missing, the grandchild's root is the topmost
/// ancestor that can be read, reported with `root_inferred` and never
/// stored; with no readable ancestor, it is the parent.
pub fn a_missing_ancestor_gives_the_topmost_readable_one_test() {
  let dir = restart.temp_dir()
  let runs = stored(dir, fixtures([child, grandchild]))
  let seen = process.new_subject()
  let inferred =
    sinal.observe(o.root_inferred(), fn(_, m: o.RootInferred) {
      process.send(seen, #(m.run, m.root, m.ancestor, m.problem))
    })
  let assert Ok(#(_, state)) = runner.load(runs, grandchild)
  #(state.root, state.root_exact) |> should.equal(#(child, False))
  string.contains(record.encode(state), "\"root\"") |> should.be_false
  let assert Ok(#(_, state)) = runner.load(runs, child)
  #(state.root, state.root_exact) |> should.equal(#(root, False))
  let events = collect(seen, [])
  detach([inferred])
  events
  |> should.equal([
    #(grandchild, child, root, o.AncestorMissing),
    #(child, root, root, o.AncestorMissing),
  ])
  restart.remove_dir(dir)
}

/// An unreadable ancestor, or a chain of parents longer than a family can
/// be, ends the walk at the topmost ancestor read (the parent when none
/// was).
pub fn an_unreadable_or_overlong_chain_is_inferred_test() {
  let dir = restart.temp_dir()
  let runs =
    stored(dir, [
      #(child, "{\"format\":\"fabric.run\",\"version\":7}"),
      #(grandchild, fixture(grandchild)),
    ])
  let assert Ok(#(_, state)) = runner.load(runs, grandchild)
  ancestry.resolve_root(runs, grandchild, state.parent)
  |> should.equal(Ok(ancestry.Inferred(child, child, o.AncestorUnreadable)))
  restart.remove_dir(dir)

  // A run id derives from its parent's, so stored records cannot form a
  // cycle; a chain longer than the bound ends there.
  let assert Ok(base) = record.decode(fixture(grandchild))
  let ids =
    list.repeat(Nil, 6)
    |> list.index_map(fn(_, i) { "deep" <> string.repeat("-1", i + 1) })
  let records =
    list.map(ids, fn(id) {
      let parent = string.drop_end(id, 2)
      let link = run.AgentParent(support.id(parent), run.ActionId(1, "r1"))
      let state =
        controller.State(
          ..base,
          run: id,
          parent: Some(link),
          root: parent,
          root_exact: False,
        )
      #(id, record.encode(state))
    })
  let dir = restart.temp_dir()
  let runs = stored(dir, records)
  let deepest = "deep-1-1-1-1-1-1"
  let assert Ok(#(_, state)) = runner.load(runs, deepest)
  // The root run `deep` is missing.
  #(state.root, state.root_exact) |> should.equal(#("deep-1", False))
  ancestry.resolve_root_within(runs, deepest, state.parent, 3)
  |> should.equal(
    Ok(ancestry.Inferred("deep-1-1-1", "deep-1-1", o.AncestryTooLong)),
  )
  restart.remove_dir(dir)
}

/// A graph child stored before roots names its parent graph, a root run:
/// the derived root is exact.
pub fn a_pre_wave_5_graph_child_reads_its_exact_root_test() {
  let records =
    list.map(
      ["graph-waiting-child.json", "graph-waiting-child-child.json"],
      fn(name) {
        let assert Ok(text) =
          restart.read_file("test/fixtures/records/" <> name)
        let assert Ok(state) = graph_record.decode(text)
        #(state.run, text)
      },
    )
  let assert [_, #(id, text)] = records
  let assert Ok(decoded) = graph_record.decode(text)
  #(decoded.root, decoded.root_exact) |> should.equal(#("graph-parent", False))
  let dir = restart.temp_dir()
  let runs = stored(dir, records)
  let assert Ok(#(_, state)) = graph_runner.load_raw(runs, id)
  #(state.root, state.root_exact) |> should.equal(#("graph-parent", True))
  restart.remove_dir(dir)
}
