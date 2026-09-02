mock import for "../index" {
  "./native" => "./native.mock"
}

import { execute, open, prepare } from "../index"

export function testPackageIndexUsesMockedNativeImport(): none {
  case open("invalid-keyword=1") {
    _: Success -> { return }
    f: Failure -> assert(false, "expected index.do to use tests/native.mock.do, but it called the real libpq adapter: ${f.error.message}")
  }
}

export function testPreparedExecuteRejectsWrongParameterCount(): none {
  database := try! open("mock")
  statement := try! prepare(database, "UPDATE widgets SET active = $1")
  case execute(statement, [true]) {
    _: Success -> assert(false, "expected parameter count mismatch")
    f: Failure -> assert(f.error.message.contains("Expected 0 parameters, received 1"), "expected bind count error")
  }
}
