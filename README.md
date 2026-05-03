# std/postgres

Small `Result`-first PostgreSQL wrapper for Doof programs. It mirrors the broad shape of `std/sqlite`, but uses PostgreSQL conventions: connections open from a connection string, prepared statements use `$1`, `$2`, ... placeholders, and execution results report `rowCount` plus the PostgreSQL command tag.

## Build Prerequisites

The native bridge links against `libpq`.

- macOS with Homebrew: `brew install libpq`
- Linux: install your distro's PostgreSQL client development package, usually `libpq-dev` or `postgresql-devel`

The package manifest includes common Homebrew include and library paths for Apple Silicon and Intel macOS.

## Usage

```doof
import { execute, executeSql, open, prepare, query, toJsonRow } from "std/postgres"

class Todo {
  id: long
  title: string
  done: bool
}

database := try open("postgresql://localhost/my_app")

try executeSql(database, `CREATE TEMP TABLE todos (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  done BOOLEAN NOT NULL
)`)

insertTodo := try prepare(database, "INSERT INTO todos(title, done) VALUES ($1, $2)")
try execute(insertTodo, ["Ship the postgres wrapper", true])
try execute(insertTodo, ["Write the README", true])

selectTodos := try prepare(database, "SELECT id, title, done FROM todos ORDER BY id")
stream := try query(selectTodos)

for item of stream {
  row := try item
  todo := try Todo.fromJsonValue(toJsonRow(row), true)
  println("#${todo.id}: ${todo.title}")
}
```

## Values

PostgreSQL parameters accept `int | long | bool | double | string | readonly byte[] | null`.

Rows return `Map<string, PostgresValue>`, where `PostgresValue` is `bool | long | double | string | readonly byte[] | null`.

- `BOOLEAN` values are exposed as `bool`
- `SMALLINT`, `INTEGER`, and `BIGINT` values are exposed as `long`
- `REAL`, `DOUBLE PRECISION`, and `NUMERIC` values are exposed as `double` when they parse cleanly, otherwise they fall back to `string`
- `BYTEA` values are exposed as `readonly byte[]`
- Other column types are returned as `string`

`toJsonRow(...)` converts `readonly byte[]` values to null so Doof JSON decoding stays predictable.

## API

### `open(connectionString: string): Result<Database, PostgresError>`

Open a PostgreSQL connection using any `libpq` connection string or URL.

### `close(database: Database): Result<void, PostgresError>`

Close a database connection. Calling `close` more than once is safe.

### `executeSql(database: Database, sql: string): Result<ExecResult, PostgresError>`

Execute SQL directly with PostgreSQL. This is useful for schema setup, temp tables, and transaction control.

`ExecResult` contains:

| Field | Type | Description |
|-------|------|-------------|
| `rowCount` | `int` | Rows affected or returned |
| `commandTag` | `string` | PostgreSQL command tag such as `INSERT 0 1` or `SELECT 2` |

### `prepare(database: Database, sql: string): Result<Statement, PostgresError>`

Compile a reusable prepared statement. Parameters use PostgreSQL's positional `$1`, `$2`, ... placeholders.

### `execute(statement: Statement, values: PostgresParam[] = []): Result<ExecResult, PostgresError>`

Reset, bind, and run a prepared statement that should not return rows. If the statement produces a row, `execute` fails so accidental `SELECT` calls do not silently discard data.

```doof
insertUser := try prepare(database, "INSERT INTO users(name, active) VALUES ($1, $2)")
result := try execute(insertUser, ["Ada", true])
println("affected rows ${result.rowCount}")
```

### `query(statement: Statement, values: PostgresParam[] = []): Result<Stream<Result<Map<string, PostgresValue>, PostgresError>>, PostgresError>`

Reset, bind, execute, and stream all rows from a prepared statement.

### `queryOne(statement: Statement, values: PostgresParam[] = []): Result<Map<string, PostgresValue> | null, PostgresError>`

Return the first row from a query, or `null` if there are no rows. Additional rows are ignored.

### `begin(database)`, `commit(database)`, `rollback(database)`

Convenience helpers for transaction control.

## Errors

All public operations return `Result<_, PostgresError>`. `PostgresError` includes:

| Field | Type | Description |
|-------|------|-------------|
| `stage` | `string` | Operation stage such as `open`, `prepare`, `bind`, `step`, or `read` |
| `code` | `string | null` | PostgreSQL SQLSTATE when available |
| `message` | `string` | Human-readable error message |
| `detail` | `string | null` | PostgreSQL detail text when available |
| `sql` | `string | null` | SQL text associated with the error when available |

## Tests

Integration tests are in [tests/postgres.test.do](tests/postgres.test.do). They return early unless one of these environment variables is set:

- `DOOF_POSTGRES_TEST_URL`
- `POSTGRES_URL`

Example:

```bash
DOOF_POSTGRES_TEST_URL=postgresql://localhost/postgres doof test tests/postgres.test.do
```