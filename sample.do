import {
  Database,
  PostgresError,
  PostgresValue,
  Statement,
  execute,
  executeSql,
  open,
  prepare,
  query,
  toJsonRow,
} from "./index"

class Todo {
  id: long
  title: string
  done: bool
}

class SampleOutput {
  connectionString: string
  inserted: int
  todos: Todo[]
}

function insertTodo(statement: Statement, title: string, done: bool): Result<void, PostgresError> {
  try execute(statement, [title, done])
  return Success()
}

function readTodo(row: Map<string, PostgresValue>): Result<Todo, PostgresError> {
  return case Todo.fromJsonValue(toJsonRow(row), true) {
    s: Success -> Success {
      value: s.value
    },
    f: Failure -> Failure {
      error: PostgresError {
        stage: "read",
        code: null,
        message: f.error,
        detail: null,
        sql: null,
      }
    }
  }
}

function fetchTodos(database: Database): Result<Todo[], PostgresError> {
  try statement := prepare(database, "SELECT id, title, done FROM todos ORDER BY id")
  try stream := query(statement)

  todos: Todo[] := []

  for item of stream {
    row := try! item
    try todo := readTodo(row)
    todos.push(todo)
  }

  return Success {
    value: todos
  }
}

function runSample(connectionString: string): Result<SampleOutput, PostgresError> {
  try database := open(connectionString)
  try executeSql(database, `CREATE TEMP TABLE todos (
    id BIGSERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    done BOOLEAN NOT NULL
  )`)

  try insertStatement := prepare(database, "INSERT INTO todos(title, done) VALUES ($1, $2)")
  try first := execute(insertStatement, ["Design a clean Doof API", true])
  try insertTodo(insertStatement, "Respect PostgreSQL parameter conventions", true)
  try insertTodo(insertStatement, "Map rows into Todo values", false)
  try todos := fetchTodos(database)

  return Success {
    value: SampleOutput {
      connectionString,
      inserted: first.rowCount + 2,
      todos,
    }
  }
}

function formatOutput(output: SampleOutput): string {
  let text = "PostgreSQL sample connection: ${output.connectionString}\n"
  text += "Inserted rows: ${output.inserted}\n"
  text += "Loaded todos: ${output.todos.length}\n"
  text += "\n"

  for todo of output.todos {
    marker := if todo.done then "x" else " "
    text += "- [${marker}] #${todo.id}: ${todo.title}\n"
  }

  return text
}

function formatError(error: PostgresError): string {
  let text = "PostgreSQL ${error.stage} failed"
  code := error.code ?? ""
  if code != "" {
    text += " (code ${code})"
  }
  text += ": ${error.message}"

  detail := error.detail ?? ""
  if detail != "" {
    text += "\nDetail: ${detail}"
  }

  sqlText := error.sql ?? ""
  if sqlText != "" {
    text += "\nSQL: ${sqlText}"
  }
  return text
}

function main(args: string[]): int {
  if args.length == 0 {
    println("Usage: doof run sample.do -- <connection-string>")
    return 1
  }

  result := runSample(args[1])

  println(case result {
    s: Success -> formatOutput(s.value),
    f: Failure -> formatError(f.error)
  })

  return case result {
    s: Success -> 0,
    f: Failure -> 1
  }
}