//// A small library-desk agent built only from Fabric's public modules.
////
//// Two application-owned tools with different inputs, outputs, and errors,
//// a policy that decides with the member in context, and a deterministic
//// model scripted over the transcript.

import fabric/agent.{type Agent}
import fabric/model.{
  type Message, type Reply, FinalAnswer, ToolCall, ToolRequest,
  ToolResultMessage, Usage, UserMessage,
}
import fabric/policy
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import json/blueprint/codec.{type Codec}

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

fn title_codec() -> Codec(String) {
  codec.field("title", codec.string())
}

pub fn book_codec() -> Codec(Book) {
  let assert Ok(book) =
    codec.record2(
      codec.required("isbn", codec.string()),
      codec.required("title", codec.string()),
      Book,
      fn(book) { book.isbn },
      fn(book) { book.title },
    )
  book
}

fn reservation_codec() -> Codec(Reservation) {
  codec.field("isbn", codec.string())
  |> codec.imap(Reservation, fn(reservation) { reservation.isbn })
}

fn confirmation_codec() -> Codec(Confirmation) {
  codec.field("confirmation", codec.string())
  |> codec.imap(Confirmation, fn(confirmation) { confirmation.code })
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
    tool.define(
      "reserve_book",
      "Reserve a book for the current member.",
      reservation_codec(),
      confirmation_codec(),
    )
      |> tool.bind(reserve_book, fn(error) {
        let AlreadyReserved = error
        tool.Explain("not reserved")
      }),
    tool.define(
      "scan_inventory",
      "Count the books on a shelf.",
      codec.field("shelf", codec.string()),
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
  case member.id, action.tool {
    "", _ -> Error("member directory unavailable")
    "guest", "reserve_book" -> Ok(policy.Deny("guests cannot reserve"))
    // A junior member's reservation waits for a guardian's approval.
    "junior", "reserve_book" ->
      Ok(policy.RequireApproval(policy.Requirement("guardian", 1)))
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
        "",
        [call("s1", "scan_inventory", "{\"shelf\":\"A\"}")],
        usage,
      )
    "reserve " <> title, [] ->
      ToolRequest(
        "",
        [call("f1", "find_book", "{\"title\":\"" <> title <> "\"}")],
        usage,
      )
    _, [found] ->
      case codec.decode_json(book_codec(), found) {
        Ok(book) ->
          ToolRequest(
            "",
            [call("r1", "reserve_book", "{\"isbn\":\"" <> book.isbn <> "\"}")],
            usage,
          )
        Error(_) -> FinalAnswer("sorry: " <> found, usage)
      }
    _, seen -> FinalAnswer("done: " <> string.join(seen, " | "), usage)
  }
}

// --- agent --------------------------------------------------------------------

pub fn librarian() -> Agent(Member) {
  agent.new(
    model.new(fn(request: model.Request) {
      Ok(scripted_librarian(request.messages))
    }),
    tools(),
    desk_policy,
  )
  |> agent.with_system_prompt("You help library members.")
  |> agent.with_max_turns(4)
  |> agent.with_max_concurrency(2)
  |> agent.with_token_budget(10_000)
}

pub fn misconfigured() -> Agent(Member) {
  librarian() |> agent.with_max_turns(0)
}

pub fn check(agent: Agent(Member)) -> Result(Nil, List(agent.ConfigError)) {
  agent.validate(agent)
}
