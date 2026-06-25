# std/postgres Guide

`std/postgres` is a small `Result`-first PostgreSQL wrapper built on `libpq`.
Its shape mirrors `std/sqlite`, but it follows PostgreSQL conventions:
connection strings for opening, `$1`-style placeholders, command tags, and
SQLSTATE error codes.

## Build Requirements

The native bridge links against `libpq`. Install the PostgreSQL client
development package for your platform before building this module.

## Lifecycle

Open a connection with `open(connectionString)` and close it with
`close(database)`. Closing more than once is safe.

Use `executeSql` for schema setup, temp tables, and transaction control. Use
`prepare` for repeated statements with `$1`, `$2`, ... placeholders.

## Parameters And Rows

Parameters accept:

```doof
int | long | bool | double | string | readonly byte[] | null
```

Rows are `Map<string, PostgresValue>`:

- `BOOLEAN` becomes `bool`
- integer types become `long`
- floating and parseable numeric values become `double`
- `BYTEA` becomes `readonly byte[]`
- other types become `string`
- SQL `NULL` becomes `null`

`toJsonRow(row)` converts byte arrays to `null` so JSON decoding stays
predictable.

## Streaming Queries

`query(statement, values)` executes the prepared statement and returns a stream
of row results. Each item is a `Result`, so row conversion errors are handled
while consuming the stream.

`queryOne` returns the first row or `null` and ignores additional rows.

## Errors

`PostgresError` includes the stage, SQLSTATE when available, message, detail,
and SQL text when relevant. Non-error SQL statuses such as zero affected rows
are represented in successful `ExecResult` values.

## API Map

Types:

- `PostgresParam`
- `PostgresValue`
- `PostgresError`
- `Database`
- `Statement`
- `ExecResult`

Lifecycle and statements:

- `open`
- `close`
- `prepare`
- `executeSql`
- `execute`
- `query`
- `queryOne`

Conversion and transactions:

- `toJsonRow`
- `begin`
- `commit`
- `rollback`

Declarations are defined in [index.do](../index.do).
