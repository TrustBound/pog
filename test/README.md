# Test

### Running tests

The tests need a PostgreSQL server. `docker-compose.yml` starts one, on the
host port 5438:

```sh
docker compose up -d --wait
export PGUSER="postgres"
export PGHOST="localhost"
export PGPASSWORD="postgres"
export PGPORT=5438
./test/reset_db.sh
gleam test
docker compose down
```

Without `PGPORT` the tests use port 5432.
