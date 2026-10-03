//// The representation behind `fabric/model.Model`: a function from one
//// request to one reply. It is generic over the request, reply and error
//// types so that `fabric/model` can define them and still alias this type.

pub opaque type Port(request, reply, error) {
  Port(call: fn(request) -> Result(reply, error))
}

pub fn new(
  call: fn(request) -> Result(reply, error),
) -> Port(request, reply, error) {
  Port(call)
}

/// Calls the model in the caller's process; the runner bounds and contains
/// the call.
pub fn call(
  port: Port(request, reply, error),
  request: request,
) -> Result(reply, error) {
  port.call(request)
}
