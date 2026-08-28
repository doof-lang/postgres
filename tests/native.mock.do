import { PostgresValue } from "../types"

export class NativeExecResult {
  isolated rowCount(): int => 0
  isolated commandTag(): string => "MOCK"
}

export class NativePostgresStatement {
  isolated bindText(index: int, value: string): Result<none, string> => Success()
  isolated bindBool(index: int, value: bool): Result<none, string> => Success()
  isolated bindInt(index: int, value: int): Result<none, string> => Success()
  isolated bindLong(index: int, value: long): Result<none, string> => Success()
  isolated bindDouble(index: int, value: double): Result<none, string> => Success()
  isolated bindBlob(index: int, value: readonly byte[]): Result<none, string> => Success()
  isolated bindNull(index: int): Result<none, string> => Success()
  isolated step(): Result<bool, string> => Success { value: false }
  isolated readCurrentRow(): Result<Map<string, PostgresValue>, string> => Success { value: {} }
  isolated reset(): Result<none, string> => Success()
  isolated finalize(): Result<none, string> => Success()
  isolated executionResult(): Result<NativeExecResult, string> => Success { value: NativeExecResult() }
}

export class NativePostgresDatabase {
  isolated static open(connectionString: string): Result<NativePostgresDatabase, string> => Success { value: NativePostgresDatabase() }
  isolated exec(sql: string): Result<NativeExecResult, string> => Success { value: NativeExecResult() }
  isolated prepare(sql: string): Result<NativePostgresStatement, string> => Success { value: NativePostgresStatement() }
  isolated close(): Result<none, string> => Success()
}
