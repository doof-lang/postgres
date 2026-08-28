mock import for "../index" {
  "./native" => "./native.mock"
}

import { open } from "../index"

export function testPackageIndexUsesMockedNativeImport(): none {
  case open("invalid-keyword=1") {
    _: Success -> { return }
    f: Failure -> assert(false, "expected index.do to use tests/native.mock.do, but it called the real libpq adapter: ${f.error.message}")
  }
}
