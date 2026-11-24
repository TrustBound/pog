# Test

### Running tests

The tests need two PostgreSQL servers: one without SSL, and one with SSL and
the test certificates of `test/fixtures/ssl`. `docker-compose.yml` starts
both, on the host ports 5438 and 5439:

```sh
docker compose up -d --wait
export PGUSER="postgres"
export PGHOST="localhost"
export PGPASSWORD="postgres"
export PGPORT=5438
export DREAM_POG_SSL_PGPORT=5439
./test/reset_db.sh
gleam test
docker compose down
```

Without `PGPORT` the tests use port 5432, and without `DREAM_POG_SSL_PGPORT`
the SSL tests use port 5439.
