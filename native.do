import { PostgresValue } from "./types"

export import class NativePostgresDatabase from "./native_postgres.hpp" {
  isolated static open(connectionString: string): Result<NativePostgresDatabase, string>
  isolated exec(sql: string): Result<NativeExecResult, string>
  isolated prepare(sql: string): Result<NativePostgresStatement, string>
  isolated close(): Result<none, string>
}

export import class NativeExecResult from "./native_postgres.hpp" {
  isolated rowsAffected(): long
  isolated commandTag(): string
}

export import class NativePostgresStatement from "./native_postgres.hpp" {
  isolated parameterCount(): int
  isolated bindText(index: int, value: string): Result<none, string>
  isolated bindBool(index: int, value: bool): Result<none, string>
  isolated bindInt(index: int, value: int): Result<none, string>
  isolated bindLong(index: int, value: long): Result<none, string>
  isolated bindDouble(index: int, value: double): Result<none, string>
  isolated bindBlob(index: int, value: readonly byte[]): Result<none, string>
  isolated bindNull(index: int): Result<none, string>
  isolated step(): Result<bool, string>
  isolated readCurrentRow(): Result<Map<string, PostgresValue>, string>
  isolated reset(): Result<none, string>
  isolated finalize(): Result<none, string>
  isolated executionResult(): Result<NativeExecResult, string>
  isolated hasResultSet(): bool
}
