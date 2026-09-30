//// Establish the ledger after the root insert and before committing its
//// initialized marker. Callers then CAS that marker before dispatching.
//// An initialized root must find its ledger; never recreate lost capacity.

import fabric/internal/budget/config
import fabric/internal/budget/ledger
import fabric/internal/budget/model as budget
import fabric/run
import fabric/store
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn pending(declaration: Option(budget.Declaration)) -> Bool {
  case declaration {
    Some(budget.Declaration(_, False)) -> True
    _ -> False
  }
}

pub fn prepare(
  runs: store.Store,
  root: String,
  parent: Option(run.Parent),
  declaration: Option(budget.Declaration),
) -> Result(Option(budget.Declaration), store.StoreError) {
  use Nil <- result.try(
    config.validate(parent == None, declaration)
    |> result.map_error(store.Unavailable),
  )
  case declaration {
    None -> Ok(None)
    Some(declaration) -> {
      let saved = case declaration.initialized {
        False -> ledger.ensure(runs, root, declaration.limits)
        True -> ledger.read(runs, root) |> result.map(fn(entry) { entry.1 })
      }
      use state <- result.try(
        saved
        |> result.map_error(fn(error) {
          store.Unavailable(
            "family budget initialization: " <> string.inspect(error),
          )
        }),
      )
      case budget.limits(state) == declaration.limits {
        True -> Ok(Some(budget.Declaration(declaration.limits, True)))
        False -> Error(store.Unavailable("the family budget limits changed"))
      }
    }
  }
}
