// Rough PostgreSQL equivalent to std/sqlite, adapted to PostgreSQL conventions.

export type PostgresParam = int | long | bool | double | string | readonly byte[] | null
export type PostgresValue = bool | long | double | string | readonly byte[] | null

export import class NativePostgresDatabase from "./native_postgres.hpp" {
  static open(connectionString: string): Result<NativePostgresDatabase, string>
  exec(sql: string): Result<NativeExecResult, string>
  prepare(sql: string): Result<NativePostgresStatement, string>
  close(): Result<void, string>
}

export import class NativeExecResult from "./native_postgres.hpp" {
  rowCount(): int
  commandTag(): string
}

export import class NativePostgresStatement from "./native_postgres.hpp" {
  bindText(index: int, value: string): Result<void, string>
  bindBool(index: int, value: bool): Result<void, string>
  bindInt(index: int, value: int): Result<void, string>
  bindLong(index: int, value: long): Result<void, string>
  bindDouble(index: int, value: double): Result<void, string>
  bindBlob(index: int, value: readonly byte[]): Result<void, string>
  bindNull(index: int): Result<void, string>
  step(): Result<bool, string>
  readCurrentRow(): Result<Map<string, PostgresValue>, string>
  reset(): Result<void, string>
  finalize(): Result<void, string>
  executionResult(): Result<NativeExecResult, string>
}

export class PostgresError {
  stage: string
  code: string | null
  message: string
  detail: string | null
  sql: string | null
}

export class ExecResult {
  rowCount: int
  commandTag: string
}

export class Database {
  native: NativePostgresDatabase
  connectionString: string
}

export class Statement {
  database: Database
  native: NativePostgresStatement
  sql: string
}

export function open(connectionString: string): Result<Database, PostgresError> {
  return case NativePostgresDatabase.open(connectionString) {
    s: Success -> Success {
      value: Database {
        native: s.value,
        connectionString,
      }
    },
    f: Failure -> Failure {
      error: decodeError("open", f.error, null)
    }
  }
}

export function close(database: Database): Result<void, PostgresError> {
  return mapNativeVoid("close", null, database.native.close())
}

function decodeError(stage: string, raw: string, sql: string | null): PostgresError {
  firstSeparator := raw.indexOf("|")
  if firstSeparator < 0 {
    return PostgresError {
      stage,
      code: null,
      message: raw,
      detail: null,
      sql,
    }
  }

  codeText := raw.substring(0, firstSeparator)
  remainder := raw.slice(firstSeparator + 1)
  secondSeparator := remainder.indexOf("|")

  let message = remainder
  let detail: string | null = null
  if secondSeparator >= 0 {
    message = remainder.substring(0, secondSeparator)
    detailText := remainder.slice(secondSeparator + 1)
    if detailText.length > 0 {
      detail = detailText
    }
  }

  let code: string | null = null
  if codeText.length > 0 {
    code = codeText
  }

  return PostgresError {
    stage,
    code,
    message,
    detail,
    sql,
  }
}

function mapNativeVoid(stage: string, sql: string | null, result: Result<void, string>): Result<void, PostgresError> {
  return case result {
    _: Success -> Success(),
    f: Failure -> Failure {
      error: decodeError(stage, f.error, sql)
    }
  }
}

function unexpectedRowError(sql: string): PostgresError {
  return PostgresError {
    stage: "step",
    code: null,
    message: "Statement unexpectedly produced a row",
    detail: null,
    sql,
  }
}

function toExecResult(result: NativeExecResult): ExecResult {
  return ExecResult {
    rowCount: result.rowCount(),
    commandTag: result.commandTag(),
  }
}

function emptyRow(): Map<string, PostgresValue> | null {
  return null
}

function readCurrentRow(statement: Statement): Result<Map<string, PostgresValue>, PostgresError> {
  return case statement.native.readCurrentRow() {
    s: Success -> Success {
      value: s.value
    },
    f: Failure -> Failure {
      error: decodeError("read", f.error, statement.sql)
    }
  }
}

export function prepare(database: Database, sql: string): Result<Statement, PostgresError> {
  return case database.native.prepare(sql) {
    s: Success -> Success {
      value: Statement {
        database,
        native: s.value,
        sql,
      }
    },
    f: Failure -> Failure {
      error: decodeError("prepare", f.error, sql)
    }
  }
}

function bindText(statement: Statement, index: int, value: string): Result<void, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindText(index, value))
}

function bindBool(statement: Statement, index: int, value: bool): Result<void, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindBool(index, value))
}

function bindInt(statement: Statement, index: int, value: int): Result<void, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindInt(index, value))
}

function bindLong(statement: Statement, index: int, value: long): Result<void, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindLong(index, value))
}

function bindDouble(statement: Statement, index: int, value: double): Result<void, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindDouble(index, value))
}

function bindBlob(statement: Statement, index: int, value: readonly byte[]): Result<void, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindBlob(index, value))
}

function bindNull(statement: Statement, index: int): Result<void, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindNull(index))
}

function bindValue(statement: Statement, index: int, value: PostgresParam): Result<void, PostgresError> {
  return case value {
    text: string -> bindText(statement, index, text),
    flag: bool -> bindBool(statement, index, flag),
    number: int -> bindInt(statement, index, number),
    whole: long -> bindLong(statement, index, whole),
    decimal: double -> bindDouble(statement, index, decimal),
    bytes: readonly byte[] -> bindBlob(statement, index, bytes),
    _ -> bindNull(statement, index)
  }
}

function bindValues(statement: Statement, values: PostgresParam[] = []): Result<void, PostgresError> {
  for index of 0..<values.length {
    try bindValue(statement, index + 1, values[index])
  }

  return Success()
}

function reset(statement: Statement): Result<void, PostgresError> {
  return mapNativeVoid("reset", statement.sql, statement.native.reset())
}

function step(statement: Statement): Result<Map<string, PostgresValue> | null, PostgresError> {
  return case statement.native.step() {
    s: Success -> if s.value then readCurrentRow(statement) else Success {
      value: emptyRow()
    },
    f: Failure -> Failure {
      error: decodeError("step", f.error, statement.sql)
    }
  }
}

class RowStream {
  statement: Statement

  next(): Result<Map<string, PostgresValue>, PostgresError> | null {
    case statement.native.step() {
      s: Success -> {
        if s.value {
          return readCurrentRow(statement)
        } else {
          return null
        }
      }
      f: Failure -> return Failure {
        error: decodeError("step", f.error, statement.sql)
      }
    }
  }
}

export function query(statement: Statement, values: PostgresParam[] = []): Result<Stream<Result<Map<string, PostgresValue>, PostgresError> >, PostgresError> {
  try reset(statement)
  try bindValues(statement, values)
  return Success { value: RowStream(statement) }
}

export function execute(statement: Statement, values: PostgresParam[] = []): Result<ExecResult, PostgresError> {
  try reset(statement)
  try bindValues(statement, values)
  try row := step(statement)

  if row != null {
    return Failure {
      error: unexpectedRowError(statement.sql)
    }
  }

  return case statement.native.executionResult() {
    s: Success -> Success {
      value: toExecResult(s.value)
    },
    f: Failure -> Failure {
      error: decodeError("step", f.error, statement.sql)
    }
  }
}

export function executeSql(database: Database, sql: string): Result<ExecResult, PostgresError> {
  return case database.native.exec(sql) {
    s: Success -> Success {
      value: toExecResult(s.value)
    },
    f: Failure -> Failure {
      error: decodeError("execute", f.error, sql)
    }
  }
}

export function queryOne(statement: Statement, values: PostgresParam[] = []): Result<Map<string, PostgresValue> | null, PostgresError> {
  try stream := query(statement, values)
  n := stream.next()
  if n == null {
    return Success { value: emptyRow() }
  }

  case n! {
    s: Success -> return Success { value: s.value }
    f: Failure -> return Failure { error: f.error }
  }
}

function toJsonValue(value: PostgresValue): JsonValue {
  case value {
    flag: bool -> return flag
    whole: long -> return whole
    decimal: double -> return decimal
    text: string -> return text
    _ -> return null
  }
}

export function toJsonRow(row: Map<string, PostgresValue>): Map<string, JsonValue> {
  jsonRow: Map<string, JsonValue> := {}
  for key, value of row {
    jsonRow[key] = toJsonValue(value)
  }
  return jsonRow
}

export function begin(database: Database): Result<void, PostgresError> {
  try executeSql(database, "BEGIN")
  return Success()
}

export function commit(database: Database): Result<void, PostgresError> {
  try executeSql(database, "COMMIT")
  return Success()
}

export function rollback(database: Database): Result<void, PostgresError> {
  try executeSql(database, "ROLLBACK")
  return Success()
}