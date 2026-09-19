import fabric
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn version_test() {
  fabric.version()
  |> should.equal("0.1.0")
}
