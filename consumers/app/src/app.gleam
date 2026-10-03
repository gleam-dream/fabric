//// A small library-desk agent built only from Fabric's public modules.
////
//// Two application-owned tools with different inputs, outputs, and errors,
//// a policy that decides with the member in context, and a deterministic
//// model scripted over the transcript. A front desk delegates acquisitions
//// to a purchasing sub-agent (starting it needs the committee's approval,
//// and each order the treasurer's) and arranges interlibrary loans with a
//// Saga workflow exposed as one tool. At start the application routes
//// Fabric's observations through a Sinal forwarder, so a slow handler never
//// holds up a run.

import fabric/agent.{type Agent}
import fabric/model.{
  type Message, type Reply, FinalAnswer, ToolCall, ToolRequest,
  ToolResultMessage, Usage, UserMessage,
}
import fabric/policy
import fabric/run
import fabric/tool
import fabric_saga
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import json/blueprint/codec.{type Codec}
import saga
import saga/execution
import sinal/forwarder

// --- observation ----------------------------------------------------------------

/// The supervisor of the forwarder that runs Fabric's event handlers.
pub opaque type Observation {
  Observation(supervisor: Pid)
}

fn fabric_events() -> List(String) {
  ["fabric"]
}

/// Application start: supervises a forwarder, then routes every `[fabric]`
/// event through it. Handlers attached to Fabric's events then run in the
/// forwarder's process; when it is full, events are dropped and counted
/// rather than holding up a run.
pub fn start_observation() -> Result(Observation, actor.StartError) {
  let events = forwarder.new(process.new_name("app-fabric-observation"))
  let started =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(events))
    |> static_supervisor.start
  case started {
    Ok(started) -> {
      forwarder.route(fabric_events(), events)
      Ok(Observation(started.pid))
    }
    Error(error) -> Error(error)
  }
}

/// Application shutdown, from the process that called `start_observation`:
/// later events are emitted synchronously again, and the forwarder stops
/// (events still in flight are dropped).
pub fn stop_observation(observation: Observation) -> Nil {
  forwarder.unroute(fabric_events())
  process.unlink(observation.supervisor)
  process.send_abnormal_exit(observation.supervisor, atom.create("shutdown"))
}

// --- application types --------------------------------------------------------

pub type Member {
  Member(id: String, scan_gate: Option(Subject(Subject(Nil))))
}

pub type Book {
  Book(isbn: String, title: String)
}

pub type BookError {
  NotInCatalog(title: String)
}

pub type Reservation {
  Reservation(isbn: String)
}

pub type Confirmation {
  Confirmation(code: String)
}

pub type ReserveError {
  AlreadyReserved
}

pub fn member(id: String) -> Member {
  Member(id, None)
}

/// A member whose inventory scans announce themselves on `arrivals` and
/// wait until released.
pub fn member_with_scan_gate(
  id: String,
  arrivals: Subject(Subject(Nil)),
) -> Member {
  Member(id, Some(arrivals))
}

// --- codecs ---------------------------------------------------------------------

/// An object with the one string property `name`, read as its text.
fn text_field(name: String) -> Codec(String) {
  use text <- codec.field(name, codec.string(), get: fn(text) { text })
  codec.success(text)
}

fn title_codec() -> Codec(String) {
  text_field("title")
}

pub fn book_codec() -> Codec(Book) {
  use isbn <- codec.field("isbn", codec.string(), get: fn(book) { book.isbn })
  use title <- codec.field("title", codec.string(), get: fn(book) { book.title })
  codec.success(Book(isbn:, title:))
}

fn reservation_codec() -> Codec(Reservation) {
  use isbn <- codec.field("isbn", codec.string(), get: fn(reservation) {
    reservation.isbn
  })
  codec.success(Reservation(isbn))
}

fn confirmation_codec() -> Codec(Confirmation) {
  use code <- codec.field("confirmation", codec.string(), get: fn(confirmation) {
    confirmation.code
  })
  codec.success(Confirmation(code))
}

// --- tools --------------------------------------------------------------------

fn find_book(_member: Member, title: String) -> Result(Book, BookError) {
  case title {
    "Dune" -> Ok(Book("978-0441013593", "Dune"))
    other -> Error(NotInCatalog(other))
  }
}

fn reserve_book(
  member: Member,
  reservation: Reservation,
) -> Result(Confirmation, ReserveError) {
  case reservation.isbn {
    "" -> Error(AlreadyReserved)
    isbn -> Ok(Confirmation(member.id <> ":" <> isbn))
  }
}

fn scan_inventory(member: Member, shelf: String) -> Result(Int, Nil) {
  case member.scan_gate {
    Some(arrivals) -> {
      let release = process.new_subject()
      process.send(arrivals, release)
      let _ = process.receive(release, 60_000)
      Nil
    }
    None -> Nil
  }
  Ok(string.length(shelf))
}

pub fn reserve_definition() -> tool.Definition(Reservation, Confirmation) {
  tool.define(
    "reserve_book",
    "Reserve a book for the current member.",
    reservation_codec(),
    confirmation_codec(),
  )
}

pub fn tools() -> List(tool.Tool(Member)) {
  [
    tool.define(
      "find_book",
      "Find a book by its exact title.",
      title_codec(),
      book_codec(),
    )
      |> tool.bind(find_book, fn(error) {
        let NotInCatalog(title) = error
        tool.Explain("no book titled " <> title)
      }),
    // A refused reservation made no change; its detail stays hidden.
    reserve_definition()
      |> tool.bind(reserve_book, fn(error) {
        let AlreadyReserved = error
        tool.Explain("not reserved")
      }),
    tool.define(
      "scan_inventory",
      "Count the books on a shelf.",
      text_field("shelf"),
      codec.int(),
    )
      |> tool.bind(scan_inventory, fn(_) { tool.Explain("scan failed") }),
  ]
}

// --- policy -------------------------------------------------------------------

pub fn desk_policy(
  member: Member,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  // Typed matching: `Some(reservation)` only for a call of this
  // definition; arguments it cannot read fail the policy.
  use reservation <- result.try(tool.input(reserve_definition(), action))
  case member.id, reservation {
    "", _ -> Error("member directory unavailable")
    "guest", Some(_) -> Ok(policy.Deny("guests cannot reserve"))
    // A junior member's reservation waits for a guardian's approval.
    "junior", Some(Reservation(isbn: _)) ->
      Ok(policy.RequireApproval(run.Requirement("guardian", 1)))
    _, _ -> Ok(policy.Allow)
  }
}

// --- model ----------------------------------------------------------------------

fn call(id: String, name: String, arguments: String) -> model.ToolCall {
  ToolCall(id, name, arguments, None, None)
}

fn results(messages: List(Message)) -> List(String) {
  list.filter_map(messages, fn(message) {
    case message {
      ToolResultMessage(_, content) -> Ok(content)
      _ -> Error(Nil)
    }
  })
}

fn prompt(messages: List(Message)) -> String {
  case messages {
    [UserMessage(text), ..] -> text
    _ -> ""
  }
}

/// A deterministic librarian: the reply is a pure function of the
/// transcript.
pub fn scripted_librarian(messages: List(Message)) -> Reply {
  let usage = Some(Usage(input_tokens: 10, output_tokens: 5))
  case prompt(messages), results(messages) {
    "scan the inventory", [] ->
      ToolRequest(
        model.AssistantTurn(
          "",
          [call("s1", "scan_inventory", "{\"shelf\":\"A\"}")],
          None,
        ),
        usage,
      )
    "reserve " <> title, [] ->
      ToolRequest(
        model.AssistantTurn(
          "",
          [call("f1", "find_book", "{\"title\":\"" <> title <> "\"}")],
          None,
        ),
        usage,
      )
    _, [found] ->
      case codec.decode_json(book_codec(), found) {
        Ok(book) ->
          ToolRequest(
            model.AssistantTurn(
              "",
              [call("r1", "reserve_book", "{\"isbn\":\"" <> book.isbn <> "\"}")],
              None,
            ),
            usage,
          )
        Error(_) -> FinalAnswer("sorry: " <> found, usage)
      }
    _, seen -> FinalAnswer("done: " <> string.join(seen, " | "), usage)
  }
}

// --- agent --------------------------------------------------------------------

pub fn librarian_spec() -> agent.Spec(Member) {
  agent.new(
    "librarian",
    model.new(fn(request: model.Request) {
      Ok(scripted_librarian(request.messages))
    }),
    tools(),
    desk_policy,
  )
  |> agent.with_system_prompt("You help library members.")
  |> agent.with_limits(
    agent.Limits(
      ..agent.default_limits(),
      max_turns: 4,
      max_concurrency: 2,
      token_budget: Some(10_000),
    ),
  )
}

/// Built once, at boot: every problem is reported before any run.
pub fn librarian() -> Result(Agent(Member), List(agent.ConfigError)) {
  agent.build(librarian_spec())
}

pub fn misconfigured() -> Result(Agent(Member), List(agent.ConfigError)) {
  librarian_spec()
  |> agent.with_limits(agent.Limits(..agent.default_limits(), max_turns: 0))
  |> agent.build
}

// --- acquisitions: a sub-agent ------------------------------------------------

pub type Purchase {
  Purchase(title: String)
}

pub type Order {
  Order(summary: String)
}

fn purchase_codec() -> Codec(Purchase) {
  use title <- codec.field("title", codec.string(), get: fn(purchase) {
    purchase.title
  })
  codec.success(Purchase(title))
}

fn order_codec() -> Codec(Order) {
  use summary <- codec.field("order", codec.string(), get: fn(order) {
    order.summary
  })
  codec.success(Order(summary))
}

/// Delegating an acquisition starts the purchaser as a sub-agent.
pub fn acquire_definition() -> tool.Definition(Purchase, Order) {
  tool.define(
    "acquire",
    "Have the purchaser acquire a book the library does not have.",
    purchase_codec(),
    order_codec(),
  )
}

/// Every order the purchaser places needs the treasurer's approval.
pub fn purchasing_policy(
  _member: Member,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  use order <- result.try(tool.input(order_definition(), action))
  case order {
    Some(_) -> Ok(policy.RequireApproval(run.Requirement("treasurer", 1)))
    None -> Ok(policy.Allow)
  }
}

pub fn order_definition() -> tool.Definition(Purchase, String) {
  tool.define(
    "order_book",
    "Place a purchase order for a title.",
    purchase_codec(),
    text_field("po"),
  )
}

/// Places a purchase order for a title.
pub fn purchaser() -> Agent(Member) {
  let order =
    order_definition()
    |> tool.bind(
      fn(_member, purchase: Purchase) -> Result(String, Nil) {
        Ok("PO-" <> purchase.title)
      },
      fn(_) { tool.Explain("order failed") },
    )
  let assert Ok(purchaser) =
    agent.new(
      "purchaser",
      model.new(fn(request: model.Request) {
        let usage = Some(Usage(input_tokens: 4, output_tokens: 2))
        Ok(case prompt(request.messages), results(request.messages) {
          "buy " <> title, [] ->
            ToolRequest(
              model.AssistantTurn(
                "",
                [call("o1", "order_book", "{\"title\":\"" <> title <> "\"}")],
                None,
              ),
              usage,
            )
          _, seen -> FinalAnswer("ordered " <> string.join(seen, ", "), usage)
        })
      }),
      [order],
      purchasing_policy,
    )
    |> agent.build
  purchaser
}

/// Starting the purchaser needs the acquisitions committee's approval.
pub fn front_desk_policy(
  member: Member,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.target {
    policy.StartAgent(..) ->
      Ok(policy.RequireApproval(run.Requirement("committee", 1)))
    policy.InvokeTool -> desk_policy(member, action)
  }
}

// --- interlibrary loans: a Saga workflow as a tool ------------------------------

pub type Loan {
  Loan(title: String)
}

pub type LoanError {
  NoCourier(title: String)
}

/// Request a copy from a partner library, then book a courier for it. A
/// title no courier carries cancels the request.
pub fn loan_workflow() -> saga.Workflow(Loan, String, LoanError, Nil) {
  let request =
    saga.step("request_copy", fn(loan: Loan) { Ok("REQ-" <> loan.title) })
    |> saga.undo(fn(_) { Ok(Nil) })
  let courier =
    saga.step("book_courier", fn(pair: #(Loan, String)) {
      let #(loan, request) = pair
      case loan.title {
        "Lost Scroll" -> Error(NoCourier(loan.title))
        _ -> Ok(request <> "/COURIER")
      }
    })
  let assert Ok(workflow) =
    saga.define("interlibrary_loan", fn(loan) {
      let requested = saga.perform(loan, request)
      saga.perform(saga.both(loan, requested), courier)
    })
  workflow
}

pub fn loan_tool() -> tool.Tool(Member) {
  fabric_saga.tool(
    tool.define(
      "interlibrary_loan",
      "Borrow a book from a partner library.",
      {
        use title <- codec.field("title", codec.string(), get: fn(loan) {
          loan.title
        })
        codec.success(Loan(title))
      },
      text_field("delivery"),
    ),
    loan_workflow(),
    execution.config(),
    explain: fn(error) {
      let NoCourier(title) = error
      "no courier carries " <> title
    },
    // A stopped loan waits this long for Saga to undo what it booked.
    rollback_within: 10_000,
  )
}

// --- the front desk -------------------------------------------------------------

/// Acquires a book through the purchaser, or borrows one through an
/// interlibrary loan.
pub fn front_desk() -> Agent(Member) {
  let assert Ok(desk) =
    agent.new(
      "front-desk",
      model.new(fn(request: model.Request) {
        let usage = Some(Usage(input_tokens: 10, output_tokens: 5))
        Ok(case prompt(request.messages), results(request.messages) {
          "acquire " <> title, [] ->
            ToolRequest(
              model.AssistantTurn(
                "",
                [call("a1", "acquire", "{\"title\":\"" <> title <> "\"}")],
                None,
              ),
              usage,
            )
          "borrow " <> title, [] ->
            ToolRequest(
              model.AssistantTurn(
                "",
                [
                  call(
                    "l1",
                    "interlibrary_loan",
                    "{\"title\":\"" <> title <> "\"}",
                  ),
                ],
                None,
              ),
              usage,
            )
          _, seen -> FinalAnswer("done: " <> string.join(seen, " | "), usage)
        })
      }),
      [loan_tool()],
      front_desk_policy,
    )
    |> agent.with_sub_agent(
      acquire_definition(),
      to: purchaser(),
      prompt: fn(purchase: Purchase) { "buy " <> purchase.title },
      output: fn(text) { Ok(Order(text)) },
    )
    |> agent.build
  desk
}
