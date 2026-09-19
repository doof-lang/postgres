// Rough PostgreSQL equivalent to std/sqlite, adapted to PostgreSQL conventions.

import { NativeExecResult, NativePostgresDatabase, NativePostgresStatement } from "./native"
import { PostgresParam, PostgresValue } from "./types"

export { NativeExecResult, NativePostgresDatabase, NativePostgresStatement } from "./native"
export { PostgresParam, PostgresValue } from "./types"

export class PostgresError {
  stage: string
  code: string | none
  sqlState: string | none
  message: string
  detail: string | none
  sql: string | none
}

export class ExecResult {
  rowsAffected: long
  commandTag: string
}

export class Database {
  native: NativePostgresDatabase
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
      }
    },
    f: Failure -> Failure {
      error: decodeError("open", f.error, none)
    }
  }
}

export function close(database: Database): Result<none, PostgresError> {
  return mapNativeVoid("close", none, database.native.close())
}

function decodeError(stage: string, raw: string, sql: string | none): PostgresError {
  firstSeparator := raw.indexOf("|")
  if firstSeparator < 0 {
    return PostgresError {
      stage,
      code: none,
      sqlState: none,
      message: raw,
      detail: none,
      sql,
    }
  }

  codeText := raw.substring(0, firstSeparator)
  remainder := raw.slice(firstSeparator + 1)
  secondSeparator := remainder.indexOf("|")

  let message = remainder
  let detail: string | none = none
  if secondSeparator >= 0 {
    message = remainder.substring(0, secondSeparator)
    detailText := remainder.slice(secondSeparator + 1)
    if detailText.length > 0 {
      detail = detailText
    }
  }

  let code: string | none = none
  if codeText.length > 0 {
    code = codeText
  }

  return PostgresError {
    stage,
    code,
    sqlState: code,
    message,
    detail,
    sql,
  }
}

function mapNativeVoid(stage: string, sql: string | none, result: Result<none, string>): Result<none, PostgresError> {
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
    code: none,
    sqlState: none,
    message: "Statement unexpectedly produced a row",
    detail: none,
    sql,
  }
}

function toExecResult(result: NativeExecResult): ExecResult {
  return ExecResult {
    rowsAffected: result.rowsAffected(),
    commandTag: result.commandTag(),
  }
}

function emptyRow(): Map<string, PostgresValue> | none {
  return none
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

function bindText(statement: Statement, index: int, value: string): Result<none, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindText(index, value))
}

function bindBool(statement: Statement, index: int, value: bool): Result<none, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindBool(index, value))
}

function bindInt(statement: Statement, index: int, value: int): Result<none, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindInt(index, value))
}

function bindLong(statement: Statement, index: int, value: long): Result<none, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindLong(index, value))
}

function bindDouble(statement: Statement, index: int, value: double): Result<none, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindDouble(index, value))
}

function bindBlob(statement: Statement, index: int, value: readonly byte[]): Result<none, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindBlob(index, value))
}

function bindNull(statement: Statement, index: int): Result<none, PostgresError> {
  return mapNativeVoid("bind", statement.sql, statement.native.bindNull(index))
}

function bindValue(statement: Statement, index: int, value: PostgresParam): Result<none, PostgresError> {
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

function bindValues(statement: Statement, values: PostgresParam[] = []): Result<none, PostgresError> {
  expected := statement.native.parameterCount()
  if values.length != expected {
    return Failure {
      error: PostgresError {
        stage: "bind",
        code: none,
        sqlState: none,
        message: "Expected ${expected} parameters, received ${values.length}",
        detail: none,
        sql: statement.sql,
      }
    }
  }

  for index of 0..<values.length {
    try bindValue(statement, index + 1, values[index])
  }

  return Success()
}

function reset(statement: Statement): Result<none, PostgresError> {
  return mapNativeVoid("reset", statement.sql, statement.native.reset())
}

function step(statement: Statement): Result<Map<string, PostgresValue> | none, PostgresError> {
  case statement.native.step() {
    s: Success -> {
      if s.value {
        case readCurrentRow(statement) {
          row: Success -> return Success { value: row.value }
          error: Failure -> return Failure { error: error.error }
        }
      }
      return Success { value: none }
    }
    f: Failure -> return Failure {
      error: decodeError("step", f.error, statement.sql),
    }
  }
}

class RowStream implements Stream<Result<Map<string, PostgresValue>, PostgresError> > {
  statement: Statement
  let currentRow: Map<string, PostgresValue> = {}
  let currentError: PostgresError | none = none
  let finished = false

  next(): bool {
    if finished {
      return false
    }

    case statement.native.step() {
      s: Success -> {
        if s.value {
          case readCurrentRow(statement) {
            row: Success -> {
              this.currentRow = row.value
              this.currentError = none
            }
            error: Failure -> {
              this.currentError = error.error
              this.finished = true
            }
          }
          return true
        } else {
          this.finished = true
          return false
        }
      }
      f: Failure -> {
        this.currentError = decodeError("step", f.error, statement.sql)
        this.finished = true
        return true
      }
    }
  }

  value(): Result<Map<string, PostgresValue>, PostgresError> {
    if this.currentError != none {
      return Failure { error: this.currentError! }
    }
    return Success { value: this.currentRow }
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

  if row != none || statement.native.hasResultSet() {
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

export function queryOne(statement: Statement, values: PostgresParam[] = []): Result<Map<string, PostgresValue> | none, PostgresError> {
  try stream := query(statement, values)
  if !stream.next() {
    return Success { value: none }
  }

  case stream.value() {
    s: Success -> return Success { value: s.value }
    f: Failure -> return Failure { error: f.error }
  }
}

function toSerialValue(value: PostgresValue): SerialValue {
  case value {
    flag: bool -> return flag
    whole: long -> return whole
    decimal: double -> return decimal
    text: string -> return text
    _ -> return none
  }
}

export function toJsonRow(row: Map<string, PostgresValue>): Map<string, SerialValue> {
  jsonRow: Map<string, SerialValue> := {}
  for key, value of row {
    jsonRow[key] = toSerialValue(value)
  }
  return jsonRow
}

export function begin(database: Database): Result<none, PostgresError> {
  try executeSql(database, "BEGIN")
  return Success()
}

export function commit(database: Database): Result<none, PostgresError> {
  try executeSql(database, "COMMIT")
  return Success()
}

export function rollback(database: Database): Result<none, PostgresError> {
  try executeSql(database, "ROLLBACK")
  return Success()
}
