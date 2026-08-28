import {
  Database,
  PostgresValue,
  close,
  execute,
  open,
  prepare,
  query,
  queryOne,
} from "../index"

import isolated function env(name: string): Result<string, string> from "../native_postgres_test_support.hpp" as doof_postgres_test_support::env

function openTestDatabase(): Database | none {
  case env("DOOF_POSTGRES_TEST_URL") {
    s: Success -> return try! open(s.value)
    _: Failure -> return none
  }
}

function columnValue(row: Map<string, PostgresValue>, name: string): PostgresValue {
  for key, value of row {
    if key == name {
      return value
    }
  }

  assert(false, "expected postgres row column ${name}")
  return none
}

function assertLong(value: PostgresValue, expected: long): none {
  case value {
    actual: long -> assert(actual == expected, "expected ${expected}, got ${actual}")
    _ -> assert(false, "expected postgres value to be an integer")
  }
}

export function testQueryOneReturnsNoneWhenNoRowsMatch(): none {
  database := openTestDatabase() else { return }
  statement := try! prepare(database, "SELECT 1 AS value WHERE FALSE")

  row := try! queryOne(statement)

  assert(row == none, "expected queryOne to return none")
  try! close(database)
}

export function testQueryOneReturnsFirstRow(): none {
  database := openTestDatabase() else { return }
  statement := try! prepare(database, "SELECT value FROM (VALUES (1), (2)) AS rows(value) ORDER BY value")

  row := try! queryOne(statement)

  assert(row != none, "expected queryOne to return a row")
  assertLong(columnValue(row!, "value"), 1)
  try! close(database)
}

export function testQueryStreamsEveryRow(): none {
  database := openTestDatabase() else { return }
  statement := try! prepare(database, "SELECT value FROM (VALUES (1), (2)) AS rows(value) ORDER BY value")
  stream := try! query(statement)
  let expected: long = 1

  for item of stream {
    row := try! item
    assertLong(columnValue(row, "value"), expected)
    expected += 1
  }

  assert(expected == 3, "expected two streamed rows")
  try! close(database)
}

export function testExecuteRejectsRowProducingStatement(): none {
  database := openTestDatabase() else { return }
  statement := try! prepare(database, "SELECT 1 AS value")

  case execute(statement) {
    _: Success -> assert(false, "expected execute to reject a row-producing statement")
    f: Failure -> assert(f.error.message.contains("unexpectedly produced a row"), "expected execute row error")
  }

  try! close(database)
}
