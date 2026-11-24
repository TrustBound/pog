import dream_pog as pog
import exception
import gleam/dynamic
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/time/calendar
import gleam/time/timestamp
import gleeunit

pub fn main() {
  gleeunit.main()
}

fn disconnect(db: actor.Started(a)) -> Nil {
  process.send_exit(db.pid)
}

fn start_default() -> actor.Started(pog.Connection) {
  let assert Ok(started) =
    process.new_name("pog_test")
    |> default_config
    |> pog.start
  started
}

@external(erlang, "dream_pog_test_ffi", "env_port")
fn env_port(name: String, default: Int) -> Int

fn default_config(name) {
  pog.Config(
    ..pog.default_config(name),
    port: env_port("PGPORT", 5432),
    database: "gleam_pog_test",
    password: Some("postgres"),
    pool_size: 1,
  )
}

pub fn url_config_everything_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.port(1234)
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(Some("p"))

  assert pog.url_config(name, "postgres://u:p@db.test:1234/my_db")
    == Ok(expected)
}

pub fn url_config_alternative_postgres_protocol_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.port(1234)
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(Some("p"))
  assert pog.url_config(name, "postgresql://u:p@db.test:1234/my_db")
    == Ok(expected)
}

pub fn url_config_not_postgres_protocol_test() {
  let name = process.new_name("pog_test")
  assert pog.url_config(name, "foo://u:p@db.test:1234/my_db") == Error(Nil)
}

pub fn url_config_no_password_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.port(1234)
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(None)
  assert pog.url_config(name, "postgres://u@db.test:1234/my_db") == Ok(expected)
}

pub fn url_config_no_port_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.port(5432)
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(None)
  assert pog.url_config(name, "postgres://u@db.test/my_db") == Ok(expected)
}

pub fn url_config_path_slash_test() {
  let name = process.new_name("pog_test")
  assert pog.url_config(name, "postgres://u:p@db.test:1234/my_db/foo")
    == Error(Nil)
}

fn url_ssl(query: String) -> Result(pog.Ssl, Nil) {
  let name = process.new_name("pog_test")
  case pog.url_config(name, "postgres://u:p@db.test:1234/my_db?" <> query) {
    Ok(config) -> Ok(config.ssl)
    Error(Nil) -> Error(Nil)
  }
}

pub fn url_config_sslmode_disable_test() {
  assert url_ssl("sslmode=disable") == Ok(pog.SslDisabled)
}

pub fn url_config_sslmode_require_test() {
  assert url_ssl("sslmode=require") == Ok(pog.SslUnverified)
}

pub fn url_config_sslmode_verify_ca_checks_the_chain_only_test() {
  assert url_ssl("sslmode=verify-ca") == Ok(pog.SslVerifiedChainOnly)
}

pub fn url_config_sslmode_verify_full_test() {
  assert url_ssl("sslmode=verify-full") == Ok(pog.SslVerified)
}

pub fn url_config_sslrootcert_with_verify_full_test() {
  assert url_ssl("sslmode=verify-full&sslrootcert=/certs/ca.crt")
    == Ok(pog.SslVerifiedCaFile("/certs/ca.crt"))
}

pub fn url_config_sslrootcert_with_verify_ca_test() {
  assert url_ssl("sslrootcert=/certs/ca.crt&sslmode=verify-ca")
    == Ok(pog.SslVerifiedChainOnlyCaFile("/certs/ca.crt"))
}

pub fn url_config_sslrootcert_is_percent_decoded_test() {
  assert url_ssl("sslmode=verify-full&sslrootcert=%2Fmy%20certs%2Fca.crt")
    == Ok(pog.SslVerifiedCaFile("/my certs/ca.crt"))
}

// libpq: with a root certificate file, `require` behaves like `verify-ca`.
pub fn url_config_sslrootcert_with_require_checks_the_chain_test() {
  assert url_ssl("sslmode=require&sslrootcert=/certs/ca.crt")
    == Ok(pog.SslVerifiedChainOnlyCaFile("/certs/ca.crt"))
}

// libpq: without SSL, the root certificate file is not used.
pub fn url_config_sslrootcert_with_disable_test() {
  assert url_ssl("sslmode=disable&sslrootcert=/certs/ca.crt")
    == Ok(pog.SslDisabled)
}

// libpq: `sslrootcert=system` uses the trusted CAs of the system, its
// default sslmode is `verify-full`, and a weaker sslmode is an error.
pub fn url_config_sslrootcert_system_test() {
  assert url_ssl("sslmode=verify-full&sslrootcert=system")
    == Ok(pog.SslVerified)
  assert url_ssl("sslrootcert=system") == Ok(pog.SslVerified)
  assert url_ssl("sslmode=verify-ca&sslrootcert=system") == Error(Nil)
  assert url_ssl("sslmode=require&sslrootcert=system") == Error(Nil)
  assert url_ssl("sslmode=disable&sslrootcert=system") == Error(Nil)
}

pub fn url_config_unknown_sslmode_test() {
  assert url_ssl("sslmode=prefer") == Error(Nil)
}

// libpq: when a setting occurs more than one time, the last value is used.
pub fn url_config_repeated_setting_takes_the_last_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.port(1234)
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(Some("p"))
  assert pog.url_config(
      name,
      "postgres://u:p@db.test:1234/my_db?sslmode=disable&sslmode=require",
    )
    == Ok(pog.Config(..expected, ssl: pog.SslUnverified))
  assert pog.url_config(
      name,
      "postgres://u:p@db.test:1234/my_db?sslmode=require&sslmode=disable",
    )
    == Ok(pog.Config(..expected, ssl: pog.SslDisabled))
  assert pog.url_config(
      name,
      "postgres://u:p@db.test:1234/my_db?sslmode=verify-full&sslrootcert=/a.crt&sslrootcert=/b.crt",
    )
    == Ok(pog.Config(..expected, ssl: pog.SslVerifiedCaFile("/b.crt")))
}

pub fn inserting_new_rows_test() {
  let db = start_default()
  let sql =
    "
  INSERT INTO
    cats
  VALUES
    (DEFAULT, 'bill', true, ARRAY ['black'], now(), '2020-03-04'),
    (DEFAULT, 'felix', false, ARRAY ['grey'], now(), '2020-03-05')"
  let assert Ok(returned) = pog.query(sql) |> pog.execute(db.data)

  assert returned.count == 2
  assert returned.rows == []

  disconnect(db)
}

pub fn inserting_new_rows_and_returning_test() {
  let db = start_default()
  let sql =
    "
  INSERT INTO
    cats
  VALUES
    (DEFAULT, 'bill', true, ARRAY ['black'], now(), '2020-03-04'),
    (DEFAULT, 'felix', false, ARRAY ['grey'], now(), '2020-03-05')
  RETURNING
    name"
  let assert Ok(returned) =
    pog.query(sql)
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)

  assert returned.count == 2
  assert returned.rows == ["bill", "felix"]

  disconnect(db)
}

// A command without a row count, such as CREATE TABLE or SET, gives the
// count 0, as `PQcmdTuples` of libpq.
pub fn command_without_row_count_test() {
  let db = start_default()
  assert pog.query("CREATE TEMPORARY TABLE count_test (id int)")
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 0, rows: []))
  assert pog.query("SET search_path TO public")
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 0, rows: []))
  disconnect(db)
}

pub fn selecting_rows_test() {
  let db = start_default()
  let sql =
    "
    INSERT INTO
      cats
    VALUES
      (DEFAULT, 'neo', true, ARRAY ['black'], '2022-10-10 11:30:30.1', '2020-03-04')
    RETURNING
      id"

  let assert Ok(pog.Returned(rows: [id], ..)) =
    pog.query(sql)
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(db.data)

  let assert Ok(returned) =
    pog.query("SELECT * FROM cats WHERE id = $1")
    |> pog.parameter(pog.int(id))
    |> pog.returning({
      use x0 <- decode.field(0, decode.int)
      use x1 <- decode.field(1, decode.string)
      use x2 <- decode.field(2, decode.bool)
      use x3 <- decode.field(3, decode.list(decode.string))
      use x4 <- decode.field(4, pog.timestamp_decoder())
      use x5 <- decode.field(5, pog.calendar_date_decoder())
      decode.success(#(x0, x1, x2, x3, x4, x5))
    })
    |> pog.execute(db.data)

  assert returned.count == 1
  assert returned.rows
    == [
      #(
        id,
        "neo",
        True,
        ["black"],
        timestamp.from_calendar(
          calendar.Date(2022, calendar.October, 10),
          calendar.TimeOfDay(11, 30, 30, 100_000_000),
          calendar.utc_offset,
        ),
        calendar.Date(2020, calendar.March, 4),
      ),
    ]

  disconnect(db)
}

pub fn invalid_sql_test() {
  let db = start_default()
  let sql = "select       select"

  let assert Error(pog.PostgresqlError(code, name, message)) =
    pog.query(sql) |> pog.execute(db.data)

  assert code == "42601"
  assert name == "syntax_error"
  assert message == "syntax error at or near \"select\""

  disconnect(db)
}

pub fn insert_constraint_error_test() {
  let db = start_default()
  let sql =
    "
    INSERT INTO
      cats
    VALUES
      (900, 'bill', true, ARRAY ['black'], now(), '2020-03-04'),
      (900, 'felix', false, ARRAY ['black'], now(), '2020-03-05')"

  let assert Error(pog.ConstraintViolated(message, constraint, detail)) =
    pog.query(sql) |> pog.execute(db.data)

  assert constraint == "cats_pkey"

  assert detail == "Key (id)=(900) already exists."

  assert message
    == "duplicate key value violates unique constraint \"cats_pkey\""

  disconnect(db)
}

pub fn select_from_unknown_table_test() {
  let db = start_default()
  let sql = "SELECT * FROM unknown"

  let assert Error(pog.PostgresqlError(code, name, message)) =
    pog.query(sql) |> pog.execute(db.data)

  assert code == "42P01"
  assert name == "undefined_table"
  assert message == "relation \"unknown\" does not exist"

  disconnect(db)
}

pub fn insert_with_incorrect_type_test() {
  let db = start_default()
  let sql =
    "
      INSERT INTO
        cats
      VALUES
        (true, true, true, true)"
  let assert Error(pog.PostgresqlError(code, name, message)) =
    pog.query(sql) |> pog.execute(db.data)

  assert code == "42804"
  assert name == "datatype_mismatch"
  assert message
    == "column \"id\" is of type integer but expression is of type boolean"

  disconnect(db)
}

pub fn execute_with_wrong_number_of_arguments_test() {
  let db = start_default()
  let sql = "SELECT * FROM cats WHERE id = $1"

  assert pog.execute(pog.query(sql), db.data)
    == Error(pog.UnexpectedArgumentCount(expected: 1, got: 0))

  disconnect(db)
}

fn assert_roundtrip(
  db: actor.Started(_),
  value: a,
  type_name: String,
  encoder: fn(a) -> pog.Value,
  decoder: Decoder(a),
) -> actor.Started(_) {
  assert pog.query("select $1::" <> type_name)
    |> pog.parameter(encoder(value))
    |> pog.returning(decode.at([0], decoder))
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 1, rows: [value]))
  db
}

pub fn null_test() {
  let db = start_default()
  assert pog.query("select $1")
    |> pog.parameter(pog.null())
    |> pog.returning(decode.at([0], decode.optional(decode.int)))
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 1, rows: [None]))

  disconnect(db)
}

pub fn bool_test() {
  start_default()
  |> assert_roundtrip(True, "bool", pog.bool, decode.bool)
  |> assert_roundtrip(False, "bool", pog.bool, decode.bool)
  |> disconnect
}

pub fn int_test() {
  start_default()
  |> assert_roundtrip(0, "int", pog.int, decode.int)
  |> assert_roundtrip(1, "int", pog.int, decode.int)
  |> assert_roundtrip(2, "int", pog.int, decode.int)
  |> assert_roundtrip(3, "int", pog.int, decode.int)
  |> assert_roundtrip(4, "int", pog.int, decode.int)
  |> assert_roundtrip(5, "int", pog.int, decode.int)
  |> assert_roundtrip(-0, "int", pog.int, decode.int)
  |> assert_roundtrip(-1, "int", pog.int, decode.int)
  |> assert_roundtrip(-2, "int", pog.int, decode.int)
  |> assert_roundtrip(-3, "int", pog.int, decode.int)
  |> assert_roundtrip(-4, "int", pog.int, decode.int)
  |> assert_roundtrip(-5, "int", pog.int, decode.int)
  |> assert_roundtrip(10_000_000, "int", pog.int, decode.int)
  |> disconnect
}

pub fn float_test() {
  start_default()
  |> assert_roundtrip(0.123, "float", pog.float, decode.float)
  |> assert_roundtrip(1.123, "float", pog.float, decode.float)
  |> assert_roundtrip(2.123, "float", pog.float, decode.float)
  |> assert_roundtrip(3.123, "float", pog.float, decode.float)
  |> assert_roundtrip(4.123, "float", pog.float, decode.float)
  |> assert_roundtrip(5.123, "float", pog.float, decode.float)
  |> assert_roundtrip(-0.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-1.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-2.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-3.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-4.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-5.654, "float", pog.float, decode.float)
  |> assert_roundtrip(10_000_000.0, "float", pog.float, decode.float)
  |> disconnect
}

pub fn numeric_test() {
  let db =
    start_default()
    |> assert_roundtrip(0.0, "numeric", pog.float, pog.numeric_decoder())
    |> assert_roundtrip(10.0, "numeric", pog.float, pog.numeric_decoder())
    |> assert_roundtrip(1.1, "numeric", pog.float, pog.numeric_decoder())
    |> assert_roundtrip(1.0, "numeric", pog.float, pog.numeric_decoder())

  assert pog.query("select 1::numeric")
    |> pog.returning(decode.at([0], pog.numeric_decoder()))
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 1, rows: [1.0]))

  assert pog.query("select 0::numeric")
    |> pog.returning(decode.at([0], pog.numeric_decoder()))
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 1, rows: [0.0]))

  disconnect(db)
}

pub fn text_test() {
  start_default()
  |> assert_roundtrip("", "text", pog.text, decode.string)
  |> assert_roundtrip("✨", "text", pog.text, decode.string)
  |> assert_roundtrip("Hello, Joe!", "text", pog.text, decode.string)
  |> disconnect
}

pub fn bytea_test() {
  start_default()
  |> assert_roundtrip(<<"":utf8>>, "bytea", pog.bytea, decode.bit_array)
  |> assert_roundtrip(<<"✨":utf8>>, "bytea", pog.bytea, decode.bit_array)
  |> assert_roundtrip(
    <<"Hello, Joe!":utf8>>,
    "bytea",
    pog.bytea,
    decode.bit_array,
  )
  |> assert_roundtrip(<<1>>, "bytea", pog.bytea, decode.bit_array)
  |> assert_roundtrip(<<1, 2, 3>>, "bytea", pog.bytea, decode.bit_array)
  |> disconnect
}

pub fn array_test() {
  let decoder = decode.list(decode.string)
  start_default()
  |> assert_roundtrip(["black"], "text[]", pog.array(pog.text, _), decoder)
  |> assert_roundtrip(["gray"], "text[]", pog.array(pog.text, _), decoder)
  |> assert_roundtrip(["g", "b"], "text[]", pog.array(pog.text, _), decoder)
  |> assert_roundtrip(
    [1, 2, 3],
    "integer[]",
    pog.array(pog.int, _),
    decode.list(decode.int),
  )
  |> disconnect
}

pub fn date_test() {
  start_default()
  |> assert_roundtrip(
    calendar.Date(2022, calendar.October, 11),
    "date",
    pog.calendar_date,
    pog.calendar_date_decoder(),
  )
  |> disconnect
}

pub fn nullable_test() {
  start_default()
  |> assert_roundtrip(
    Some("Hello, Joe"),
    "text",
    pog.nullable(pog.text, _),
    decode.optional(decode.string),
  )
  |> assert_roundtrip(
    None,
    "text",
    pog.nullable(pog.text, _),
    decode.optional(decode.string),
  )
  |> assert_roundtrip(
    Some(123),
    "int",
    pog.nullable(pog.int, _),
    decode.optional(decode.int),
  )
  |> assert_roundtrip(
    None,
    "int",
    pog.nullable(pog.int, _),
    decode.optional(decode.int),
  )
  |> disconnect
}

pub fn expected_argument_type_test() {
  let db = start_default()

  assert pog.query("select $1::int")
    |> pog.returning(decode.at([0], decode.string))
    |> pog.parameter(pog.float(1.2))
    |> pog.execute(db.data)
    == Error(pog.UnexpectedArgumentType("int4", "1.2"))

  disconnect(db)
}

pub fn expected_return_type_test() {
  let db = start_default()
  assert pog.query("select 1")
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)
    == Error(
      pog.UnexpectedResultType([
        decode.DecodeError(expected: "String", found: "Int", path: ["0"]),
      ]),
    )

  disconnect(db)
}

pub fn expected_five_millis_timeout_test() {
  let db = start_default()

  assert pog.query(
      "select sub.ret from (select pg_sleep(0.05), 'OK' as ret) as sub",
    )
    |> pog.timeout(5)
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)
    == Error(pog.QueryTimeout)

  disconnect(db)
}

pub fn expected_ten_millis_no_timeout_test() {
  let db = start_default()

  assert pog.query(
      "select sub.ret from (select pg_sleep(0.01), 'OK' as ret) as sub",
    )
    |> pog.timeout(50)
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)
    == Ok(pog.Returned(1, ["OK"]))

  disconnect(db)
}

pub fn expected_ten_millis_no_default_timeout_test() {
  let name = process.new_name("pog_test")
  let assert Ok(db) =
    default_config(name)
    |> pog.start

  assert pog.query(
      "select sub.ret from (select pg_sleep(0.01), 'OK' as ret) as sub",
    )
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)
    == Ok(pog.Returned(1, ["OK"]))

  disconnect(db)
}

pub fn expected_maps_test() {
  let name = process.new_name("pog_test")
  let assert Ok(db) =
    pog.Config(..default_config(name), rows_as_map: True)
    |> pog.start

  let sql =
    "
    INSERT INTO
      cats
    VALUES
      (DEFAULT, 'neo', true, ARRAY ['black'], '2022-10-10 11:30:30', '2020-03-04')
    RETURNING
      id"

  let assert Ok(pog.Returned(rows: [id], ..)) =
    pog.query(sql)
    |> pog.returning(decode.at(["id"], decode.int))
    |> pog.execute(db.data)

  let assert Ok(returned) =
    pog.query("SELECT * FROM cats WHERE id = $1")
    |> pog.parameter(pog.int(id))
    |> pog.returning({
      use id <- decode.field("id", decode.int)
      use name <- decode.field("name", decode.string)
      use is_cute <- decode.field("is_cute", decode.bool)
      use colors <- decode.field("colors", decode.list(decode.string))
      use last_petted_at <- decode.field(
        "last_petted_at",
        pog.timestamp_decoder(),
      )
      use birthday <- decode.field("birthday", pog.calendar_date_decoder())
      decode.success(#(id, name, is_cute, colors, last_petted_at, birthday))
    })
    |> pog.execute(db.data)

  assert returned.count == 1
  assert returned.rows
    == [
      #(
        id,
        "neo",
        True,
        ["black"],
        timestamp.from_calendar(
          calendar.Date(2022, calendar.October, 10),
          calendar.TimeOfDay(11, 30, 30, 0),
          calendar.utc_offset,
        ),
        calendar.Date(2020, calendar.March, 4),
      ),
    ]

  disconnect(db)
}

pub fn transaction_commit_test() {
  let db = start_default()
  let id_decoder = decode.at([0], decode.int)
  let assert Ok(_) = pog.query("truncate table cats") |> pog.execute(db.data)

  let insert = fn(db, name) {
    let sql = "
  INSERT INTO
    cats
  VALUES
    (DEFAULT, '" <> name <> "', true, ARRAY ['black'], now(), '2020-03-04')
  RETURNING id"
    let assert Ok(pog.Returned(rows: [id], ..)) =
      pog.query(sql)
      |> pog.returning(id_decoder)
      |> pog.execute(db)
    id
  }

  // A succeeding transaction
  let assert Ok(#(id1, id2)) =
    pog.transaction(db.data, fn(db) {
      let id1 = insert(db, "one")
      let id2 = insert(db, "two")
      Ok(#(id1, id2))
    })

  // An error returning transaction, it gets rolled back
  let assert Error(pog.TransactionRolledBack("Nah bruv!")) =
    pog.transaction(db.data, fn(db) {
      let _id1 = insert(db, "two")
      let _id2 = insert(db, "three")
      Error("Nah bruv!")
    })

  // A crashing transaction, it gets rolled back
  let _ =
    exception.rescue(fn() {
      pog.transaction(db.data, fn(db) {
        let _id1 = insert(db, "four")
        let _id2 = insert(db, "five")
        panic as "testing rollbacks"
      })
    })

  let assert Ok(returned) =
    pog.query("select id from cats order by id")
    |> pog.returning(id_decoder)
    |> pog.execute(db.data)

  let assert [got1, got2] = returned.rows
  let assert True = id1 == got1
  let assert True = id2 == got2

  disconnect(db)
}

// Interceptor tests

pub fn interceptor_logging_test() {
  let interceptor =
    pog.Interceptor(fn(request) {
      let _ = request.sql
      pog.Continue
    })

  let name = process.new_name("pog_test")
  let config =
    pog.Config(..default_config(name), interceptor: Some(interceptor))

  assert config.interceptor == Some(interceptor)
}

pub fn interceptor_respond_with_data_test() {
  let test_data = dynamic.array([dynamic.int(42), dynamic.string("test")])
  let interceptor =
    pog.Interceptor(fn(_request) { pog.Respond(1, [test_data]) })

  let name = process.new_name("pog_test")
  let config =
    pog.Config(..default_config(name), interceptor: Some(interceptor))
  let assert Ok(started) = pog.start(config)

  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(#(id, name))
  }

  let result =
    pog.query("SELECT id, name FROM users")
    |> pog.returning(decoder)
    |> pog.execute(started.data)

  assert result == Ok(pog.Returned(1, [#(42, "test")]))

  disconnect(started)
}

pub fn interceptor_fail_with_error_test() {
  let interceptor =
    pog.Interceptor(fn(_request) { pog.Fail(pog.ConnectionUnavailable) })
  let name = process.new_name("pog_test")
  let config =
    pog.Config(..default_config(name), interceptor: Some(interceptor))
  let assert Ok(started) = pog.start(config)

  let result =
    pog.query("SELECT * FROM users")
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(started.data)

  assert result == Error(pog.ConnectionUnavailable)

  disconnect(started)
}

pub fn no_interceptor_is_default_test() {
  let name = process.new_name("pog_test")
  let config = default_config(name)

  assert config.interceptor == None
}

pub fn interceptor_can_inspect_sql_test() {
  let interceptor =
    pog.Interceptor(fn(request) {
      case request.sql {
        "SELECT 1" -> pog.Respond(1, [dynamic.array([dynamic.int(1)])])
        "SELECT 2" -> pog.Respond(1, [dynamic.array([dynamic.int(2)])])
        _ -> pog.Continue
      }
    })

  let name = process.new_name("pog_test")
  let config =
    pog.Config(..default_config(name), interceptor: Some(interceptor))
  let assert Ok(started) = pog.start(config)

  let result1 =
    pog.query("SELECT 1")
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(started.data)

  assert result1 == Ok(pog.Returned(1, [1]))

  let result2 =
    pog.query("SELECT 2")
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(started.data)

  assert result2 == Ok(pog.Returned(1, [2]))

  disconnect(started)
}

pub fn application_name_connection_parameter_reaches_the_server_test() {
  let assert Ok(started) =
    process.new_name("pog_test")
    |> default_config
    |> pog.connection_parameter("application_name", "dream_pog_name_test")
    |> pog.start
  let assert Ok(returned) =
    pog.query("select current_setting('application_name')")
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(started.data)
  assert returned.rows == ["dream_pog_name_test"]
  disconnect(started)
}

// Interceptor tests: pools, names, processes, transactions and crashes.

fn respond_with(value: Int) -> pog.Interceptor {
  pog.Interceptor(fn(request) {
    case request.sql {
      "select 'intercepted?'" ->
        pog.Respond(1, [dynamic.array([dynamic.int(value)])])
      "boom" -> panic as "interceptor crash"
      _ -> pog.Continue
    }
  })
}

/// Runs `select 'intercepted?'`. An interceptor of `respond_with` gives its
/// number; the server gives the text, which the decoder refuses, so without
/// an interceptor the result is an error.
fn intercepted_value(connection: pog.Connection) -> Result(Int, Nil) {
  case
    pog.query("select 'intercepted?'")
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(connection)
  {
    Ok(pog.Returned(_, [value])) -> Ok(value)
    _ -> Error(Nil)
  }
}

fn start_with(
  name: process.Name(pog.Message),
  interceptor: option.Option(pog.Interceptor),
) -> actor.Started(pog.Connection) {
  let assert Ok(started) =
    pog.Config(..default_config(name), interceptor: interceptor)
    |> pog.start
  started
}

/// Stops the pool and waits until its name is free.
fn stop_and_wait(name: process.Name(pog.Message), db: actor.Started(a)) -> Nil {
  process.send_exit(db.pid)
  wait_for_free_name(name, 100)
}

fn wait_for_free_name(name: process.Name(pog.Message), tries: Int) -> Nil {
  case process.named(name), tries {
    Error(Nil), _ -> Nil
    Ok(_), 0 -> panic as "the pool did not stop"
    Ok(_), _ -> {
      process.sleep(10)
      wait_for_free_name(name, tries - 1)
    }
  }
}

pub fn interceptor_two_pools_have_their_own_interceptors_test() {
  let a = start_with(process.new_name("pog_test"), Some(respond_with(1)))
  let b = start_with(process.new_name("pog_test"), Some(respond_with(2)))
  let c = start_with(process.new_name("pog_test"), None)
  assert intercepted_value(a.data) == Ok(1)
  assert intercepted_value(b.data) == Ok(2)
  assert intercepted_value(c.data) == Error(Nil)
  disconnect(a)
  disconnect(b)
  disconnect(c)
}

pub fn interceptor_new_pool_with_same_name_and_other_interceptor_test() {
  let name = process.new_name("pog_test")
  let first = start_with(name, Some(respond_with(1)))
  assert intercepted_value(first.data) == Ok(1)
  stop_and_wait(name, first)
  let second = start_with(name, Some(respond_with(2)))
  assert intercepted_value(second.data) == Ok(2)
  disconnect(second)
}

pub fn interceptor_new_pool_with_same_name_and_no_interceptor_test() {
  let name = process.new_name("pog_test")
  let first = start_with(name, Some(respond_with(1)))
  assert intercepted_value(first.data) == Ok(1)
  stop_and_wait(name, first)
  let second = start_with(name, None)
  assert intercepted_value(second.data) == Error(Nil)
  disconnect(second)
}

pub fn interceptor_applies_in_another_process_test() {
  let db = start_with(process.new_name("pog_test"), Some(respond_with(3)))
  let subject = process.new_subject()
  process.spawn(fn() { process.send(subject, intercepted_value(db.data)) })
  assert process.receive(subject, 1000) == Ok(Ok(3))
  disconnect(db)
}

pub fn interceptor_applies_in_transaction_test() {
  let db = start_with(process.new_name("pog_test"), Some(respond_with(4)))
  let assert Ok(value) =
    pog.transaction(db.data, fn(connection) { intercepted_value(connection) })
  assert value == 4
  disconnect(db)
}

pub fn interceptor_crash_reaches_the_caller_test() {
  let db = start_with(process.new_name("pog_test"), Some(respond_with(5)))
  let assert Error(_) =
    exception.rescue(fn() { pog.query("boom") |> pog.execute(db.data) })
  // The pool still works.
  assert intercepted_value(db.data) == Ok(5)
  disconnect(db)
}

pub fn interceptor_crash_in_transaction_gives_back_the_connection_test() {
  // pool_size is 1: if the crash kept the connection, the next transaction
  // would get no connection.
  let db = start_with(process.new_name("pog_test"), Some(respond_with(6)))
  let assert Error(_) =
    exception.rescue(fn() {
      pog.transaction(db.data, fn(connection) {
        pog.query("boom") |> pog.execute(connection)
      })
    })
  let assert Ok(value) =
    pog.transaction(db.data, fn(connection) { intercepted_value(connection) })
  assert value == 6
  let assert Ok(pog.Returned(_, [1])) =
    pog.query("select 1")
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(db.data)
  disconnect(db)
}

// Interceptor ownership tests: the interceptor belongs to the pool process.

@external(erlang, "dream_pog_test_ffi", "interceptor_rows")
fn interceptor_rows(name: process.Name(pog.Message)) -> List(dynamic.Dynamic)

@external(erlang, "dream_pog_test_ffi", "interceptor_keeper")
fn interceptor_keeper(
  name: process.Name(pog.Message),
) -> Result(process.Pid, Nil)

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: a) -> dynamic.Dynamic

/// The error of a start with the name of a pool that runs.
fn already_started(db: actor.Started(a)) -> actor.StartError {
  actor.InitExited(
    process.Abnormal(
      to_dynamic(#(atom.create("already_started"), to_dynamic(db.pid))),
    ),
  )
}

pub fn interceptor_failed_start_keeps_the_interceptor_test() {
  let name = process.new_name("pog_test")
  let first = start_with(name, Some(respond_with(11)))
  let second =
    pog.Config(..default_config(name), interceptor: Some(respond_with(12)))
    |> pog.start
  assert second == Error(already_started(first))
  assert intercepted_value(first.data) == Ok(11)
  disconnect(first)
}

pub fn interceptor_failed_start_without_interceptor_keeps_the_interceptor_test() {
  let name = process.new_name("pog_test")
  let first = start_with(name, Some(respond_with(13)))
  let second =
    pog.Config(..default_config(name), interceptor: None)
    |> pog.start
  assert second == Error(already_started(first))
  assert intercepted_value(first.data) == Ok(13)
  disconnect(first)
}

pub fn interceptor_is_removed_when_the_pool_stops_test() {
  let name = process.new_name("pog_test")
  let db = start_with(name, Some(respond_with(14)))
  let keeper = interceptor_keeper(name)
  stop_and_wait(name, db)
  case keeper {
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      let assert Ok(_) =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
        |> process.selector_receive(1000)
      Nil
    }
    Error(Nil) -> Nil
  }
  assert interceptor_rows(name) == []
  assert result.is_ok(keeper)
}

/// Waits until a process has the name, without a pause between the tries.
fn wait_for_name(name: process.Name(pog.Message), tries: Int) -> Nil {
  case process.named(name), tries {
    Ok(_), _ -> Nil
    Error(Nil), 0 -> panic as "the pool did not start"
    Error(Nil), _ -> wait_for_name(name, tries - 1)
  }
}

pub fn interceptor_applies_to_the_first_query_after_start_test() {
  let name = process.new_name("pog_test")
  let results = process.new_subject()
  process.spawn_unlinked(fn() {
    wait_for_name(name, 10_000_000)
    process.send(results, intercepted_value(pog.named_connection(name)))
  })
  let db = start_with(name, Some(respond_with(15)))
  assert process.receive(results, 1000) == Ok(Ok(15))
  disconnect(db)
}

type RaceMessage {
  Ready(go: process.Subject(Nil))
  Done(value: Int, started: Bool)
}

/// A process that starts a pool when it gets the first go message, and stops
/// the pool when it gets the second.
fn race_starter(
  name: process.Name(pog.Message),
  value: Int,
  parent: process.Subject(RaceMessage),
) -> Nil {
  process.spawn_unlinked(fn() {
    let go = process.new_subject()
    process.send(parent, Ready(go))
    let assert Ok(Nil) = process.receive(go, 1000)
    let started =
      pog.Config(..default_config(name), interceptor: Some(respond_with(value)))
      |> pog.start
    process.send(parent, Done(value, result.is_ok(started)))
    let assert Ok(Nil) = process.receive(go, 5000)
    Nil
  })
  Nil
}

fn race(rounds: Int) -> Nil {
  case rounds {
    0 -> Nil
    _ -> {
      let name = process.new_name("pog_test")
      let parent = process.new_subject()
      race_starter(name, 21, parent)
      race_starter(name, 22, parent)
      let assert Ok(Ready(go_one)) = process.receive(parent, 1000)
      let assert Ok(Ready(go_two)) = process.receive(parent, 1000)
      process.send(go_one, Nil)
      process.send(go_two, Nil)
      let assert Ok(Done(value_one, started_one)) =
        process.receive(parent, 5000)
      let assert Ok(Done(value_two, started_two)) =
        process.receive(parent, 5000)
      let winners =
        [#(value_one, started_one), #(value_two, started_two)]
        |> list.filter(fn(done) { done.1 })
        |> list.map(fn(done) { done.0 })
      let value = intercepted_value(pog.named_connection(name))
      process.send(go_one, Nil)
      process.send(go_two, Nil)
      wait_for_free_name(name, 100)
      let assert [winner] = winners
      assert value == Ok(winner)
      race(rounds - 1)
    }
  }
}

pub fn interceptor_two_starts_at_the_same_moment_test() {
  race(20)
}

// Interceptor failure tests: `Capture` with `Error(reason)` and
// `Fail(InterceptorFailed(reason))`.

fn interceptor_reason() -> dynamic.Dynamic {
  dynamic.string("the interceptor's reason")
}

fn capture_with(
  outcome: Result(Nil, dynamic.Dynamic),
) -> option.Option(pog.Interceptor) {
  Some(
    pog.Interceptor(fn(_request) { pog.Capture(on_result: fn(_) { outcome }) }),
  )
}

fn select_one(
  connection: pog.Connection,
) -> Result(pog.Returned(Int), pog.QueryError) {
  pog.query("select 1")
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(connection)
}

fn invalid_sql(
  connection: pog.Connection,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  pog.query("select       select") |> pog.execute(connection)
}

const syntax_error = pog.PostgresqlError(
  code: "42601",
  name: "syntax_error",
  message: "syntax error at or near \"select\"",
)

pub fn capture_error_fails_a_successful_query_in_a_pool_test() {
  let db =
    start_with(
      process.new_name("pog_test"),
      capture_with(Error(interceptor_reason())),
    )
  assert select_one(db.data)
    == Error(pog.InterceptorFailed(interceptor_reason()))
  disconnect(db)
}

pub fn capture_error_fails_a_failed_query_in_a_pool_test() {
  let db =
    start_with(
      process.new_name("pog_test"),
      capture_with(Error(interceptor_reason())),
    )
  assert invalid_sql(db.data)
    == Error(pog.InterceptorFailed(interceptor_reason()))
  disconnect(db)
}

pub fn capture_error_fails_a_successful_query_in_a_transaction_test() {
  let db =
    start_with(
      process.new_name("pog_test"),
      capture_with(Error(interceptor_reason())),
    )
  assert pog.transaction(db.data, select_one)
    == Error(
      pog.TransactionRolledBack(pog.InterceptorFailed(interceptor_reason())),
    )
  disconnect(db)
}

pub fn capture_error_fails_a_failed_query_in_a_transaction_test() {
  let db =
    start_with(
      process.new_name("pog_test"),
      capture_with(Error(interceptor_reason())),
    )
  assert pog.transaction(db.data, invalid_sql)
    == Error(
      pog.TransactionRolledBack(pog.InterceptorFailed(interceptor_reason())),
    )
  disconnect(db)
}

pub fn capture_ok_passes_a_successful_result_in_a_pool_test() {
  let db = start_with(process.new_name("pog_test"), capture_with(Ok(Nil)))
  assert select_one(db.data) == Ok(pog.Returned(1, [1]))
  disconnect(db)
}

pub fn capture_ok_passes_a_database_error_in_a_pool_test() {
  let db = start_with(process.new_name("pog_test"), capture_with(Ok(Nil)))
  assert invalid_sql(db.data) == Error(syntax_error)
  disconnect(db)
}

pub fn capture_ok_passes_a_successful_result_in_a_transaction_test() {
  let db = start_with(process.new_name("pog_test"), capture_with(Ok(Nil)))
  assert pog.transaction(db.data, select_one) == Ok(pog.Returned(1, [1]))
  disconnect(db)
}

pub fn capture_ok_passes_a_database_error_in_a_transaction_test() {
  let db = start_with(process.new_name("pog_test"), capture_with(Ok(Nil)))
  assert pog.transaction(db.data, invalid_sql)
    == Error(pog.TransactionRolledBack(syntax_error))
  disconnect(db)
}

/// Fails the query that sets the session setting `dream_pog.touched`, and
/// lets every other query run. The pool has one connection, so a later query
/// sees the setting only if the database ran the failed query.
fn fail_the_setting_query() -> option.Option(pog.Interceptor) {
  Some(
    pog.Interceptor(fn(request) {
      case request.sql {
        "select set_config('dream_pog.touched', 'yes', false)" ->
          pog.Fail(pog.InterceptorFailed(interceptor_reason()))
        _ -> pog.Continue
      }
    }),
  )
}

fn set_the_setting(
  connection: pog.Connection,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  pog.query("select set_config('dream_pog.touched', 'yes', false)")
  |> pog.execute(connection)
}

fn read_the_setting(connection: pog.Connection) -> option.Option(String) {
  let assert Ok(pog.Returned(_, [value])) =
    pog.query("select current_setting('dream_pog.touched', true)")
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(connection)
  value
}

pub fn fail_with_interceptor_failed_returns_the_error_in_a_pool_test() {
  let db = start_with(process.new_name("pog_test"), fail_the_setting_query())
  assert set_the_setting(db.data)
    == Error(pog.InterceptorFailed(interceptor_reason()))
  disconnect(db)
}

pub fn fail_with_interceptor_failed_does_not_run_the_query_test() {
  let db = start_with(process.new_name("pog_test"), fail_the_setting_query())
  let _ = set_the_setting(db.data)
  assert read_the_setting(db.data) == None
  disconnect(db)
}

pub fn fail_with_interceptor_failed_returns_the_error_in_a_transaction_test() {
  let db = start_with(process.new_name("pog_test"), fail_the_setting_query())
  assert pog.transaction(db.data, set_the_setting)
    == Error(
      pog.TransactionRolledBack(pog.InterceptorFailed(interceptor_reason())),
    )
  disconnect(db)
}

pub fn fail_with_interceptor_failed_on_a_disconnected_connection_test() {
  let connection =
    pog.disconnected(
      pog.Interceptor(fn(_request) {
        pog.Fail(pog.InterceptorFailed(interceptor_reason()))
      }),
    )
  assert select_one(connection)
    == Error(pog.InterceptorFailed(interceptor_reason()))
}
