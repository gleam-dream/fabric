import fabric/approvers.{type Approvers}
import fabric/reviewer
import gleam/bool
import gleam/list
import gleam/result
import warden/resource

/// Approvers that accept a warden access token issued for the validator's
/// audience and carrying the scope `approve:<requirement name>`. The answer
/// records the token's `sub` and `iss`, and the verifier `"warden"`. Call
/// it once, at boot: the agent and the request handlers share the value.
pub fn warden_approvers(validator: resource.Validator) -> Approvers(String) {
  use token, requirement <- approvers.new("warden")
  use claims <- result.try(
    resource.verify(validator, token) |> result.map_error(denial),
  )
  let scope = "approve:" <> requirement.name
  use <- bool.guard(
    !list.contains(resource.scopes(claims), scope),
    Error(approvers.NotAuthorized("the token lacks the scope " <> scope)),
  )
  reviewer.new(resource.subject(claims))
  |> result.try(reviewer.with_issuer(_, resource.issuer(claims)))
  |> result.map_error(fn(error) {
    approvers.NotAuthenticated(reviewer.describe_error(error))
  })
}

fn denial(error: resource.TokenError) -> approvers.Denial {
  let reason = resource.describe_error(error)
  case resource.error_kind(error) {
    resource.Rejected | resource.WrongAudience ->
      approvers.NotAuthenticated(reason)
    resource.Forbidden -> approvers.NotAuthorized(reason)
    resource.Unavailable -> approvers.Unavailable(reason)
  }
}
