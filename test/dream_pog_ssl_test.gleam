//// Tests for the SSL settings. They need the `postgres-ssl` server of
//// `docker-compose.yml`: its certificate has the test certificate authority
//// of `test/fixtures/ssl` as issuer, and its only name is `localhost`.

import dream_pog as pog
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/option.{Some}
import gleam/otp/actor
import gleam/string

const ca_file = "test/fixtures/ssl/ca.crt"

@external(erlang, "dream_pog_test_ffi", "env_port")
fn env_port(name: String, default: Int) -> Int

@external(erlang, "dream_pog_test_ffi", "ssl_probe")
fn ssl_probe(config: pog.Config) -> Result(Nil, String)

@external(erlang, "dream_pog_test_ffi", "system_cacerts")
fn system_cacerts() -> Dynamic

fn ssl_config(host: String, ssl: pog.Ssl) -> pog.Config {
  process.new_name("dream_pog_ssl_test")
  |> pog.default_config
  |> pog.host(host)
  |> pog.port(env_port("DREAM_POG_SSL_PGPORT", 5439))
  |> pog.password(Some("postgres"))
  |> pog.pool_size(1)
  |> pog.ssl(ssl)
}

/// Starts a pool, asks the server if the connection uses SSL, and stops the
/// pool.
fn connection_uses_ssl(config: pog.Config) -> Result(Bool, pog.QueryError) {
  let assert Ok(started) = pog.start(config)
  let result =
    pog.query("select ssl from pg_stat_ssl where pid = pg_backend_pid()")
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.execute(started.data)
  process.send_exit(started.pid)
  case result {
    Ok(pog.Returned(_, [ssl])) -> Ok(ssl)
    Ok(_) -> panic as "expected one row"
    Error(error) -> Error(error)
  }
}

fn start_error(config: pog.Config) -> String {
  case pog.start(config) {
    Error(actor.InitExited(process.Abnormal(reason))) -> {
      let assert Ok(message) = decode.run(reason, decode.string)
      message
    }
    _ -> panic as "expected the start to fail"
  }
}

pub fn ca_file_with_matching_host_name_connects_test() {
  let config = ssl_config("localhost", pog.SslVerifiedCaFile(ca_file))
  assert connection_uses_ssl(config) == Ok(True)
}

pub fn ca_file_with_other_host_name_fails_host_name_check_test() {
  let config = ssl_config("127.0.0.1", pog.SslVerifiedCaFile(ca_file))
  let assert Error(reason) = ssl_probe(config)
  assert string.contains(reason, "hostname_check_failed")
}

pub fn chain_only_with_other_host_name_connects_test() {
  let config = ssl_config("127.0.0.1", pog.SslVerifiedChainOnlyCaFile(ca_file))
  assert connection_uses_ssl(config) == Ok(True)
}

pub fn chain_only_without_ca_file_fails_with_unknown_ca_test() {
  let config = ssl_config("127.0.0.1", pog.SslVerifiedChainOnly)
  let assert Error(reason) = ssl_probe(config)
  assert string.contains(reason, "unknown_ca")
}

pub fn verified_without_ca_file_fails_with_unknown_ca_test() {
  let config = ssl_config("localhost", pog.SslVerified)
  let assert Error(reason) = ssl_probe(config)
  assert string.contains(reason, "unknown_ca")
}

pub fn missing_ca_file_fails_at_start_test() {
  let path = "test/fixtures/ssl/no_such_file.crt"
  let message =
    start_error(ssl_config("localhost", pog.SslVerifiedCaFile(path)))
  assert string.contains(message, path)
  assert string.contains(message, "enoent")
}

pub fn missing_ca_file_fails_at_start_in_chain_only_mode_test() {
  let path = "test/fixtures/ssl/no_such_file.crt"
  let message =
    start_error(ssl_config("localhost", pog.SslVerifiedChainOnlyCaFile(path)))
  assert string.contains(message, path)
  assert string.contains(message, "enoent")
}

pub fn ca_file_without_certificate_fails_at_start_test() {
  let path = "test/fixtures/ssl/README.md"
  let message =
    start_error(ssl_config("localhost", pog.SslVerifiedCaFile(path)))
  assert string.contains(message, path)
  assert string.contains(message, "no PEM certificate")
}

pub fn ca_file_does_not_change_the_system_list_test() {
  let before = system_cacerts()
  let config = ssl_config("localhost", pog.SslVerifiedCaFile(ca_file))
  assert connection_uses_ssl(config) == Ok(True)
  let config = ssl_config("127.0.0.1", pog.SslVerifiedChainOnlyCaFile(ca_file))
  assert connection_uses_ssl(config) == Ok(True)
  assert system_cacerts() == before
  // The test certificate authority is still unknown to a pool without a
  // certificate authority file.
  let assert Error(reason) = ssl_probe(ssl_config("localhost", pog.SslVerified))
  assert string.contains(reason, "unknown_ca")
}

fn url_ssl_config(host: String, query: String) -> pog.Config {
  let port = env_port("DREAM_POG_SSL_PGPORT", 5439)
  let url =
    "postgres://postgres:postgres@"
    <> host
    <> ":"
    <> int.to_string(port)
    <> "/postgres?"
    <> query
  let assert Ok(config) =
    pog.url_config(process.new_name("dream_pog_ssl_test"), url)
  pog.pool_size(config, 1)
}

pub fn url_verify_ca_with_root_cert_connects_to_other_host_name_test() {
  let config =
    url_ssl_config("127.0.0.1", "sslmode=verify-ca&sslrootcert=" <> ca_file)
  assert connection_uses_ssl(config) == Ok(True)
}

pub fn url_verify_full_with_root_cert_fails_host_name_check_test() {
  let config =
    url_ssl_config("127.0.0.1", "sslmode=verify-full&sslrootcert=" <> ca_file)
  let assert Error(reason) = ssl_probe(config)
  assert string.contains(reason, "hostname_check_failed")
}

pub fn url_verify_full_with_root_cert_connects_to_matching_host_name_test() {
  let config =
    url_ssl_config("localhost", "sslmode=verify-full&sslrootcert=" <> ca_file)
  assert connection_uses_ssl(config) == Ok(True)
}
