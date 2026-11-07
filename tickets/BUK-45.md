# BUK-45: Move the orders database to a private server and menu photos to S3

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-2 Move to the cloud |
| **Month** | 2 |
| **Sprint** | 7 |
| **Reporter** | Hussein (Engineering Lead) |
| **Assignee** | You |
| **Due** | End of sprint 7 |

## Context

> The network from BUK-42 is ready, so now we can move the two things I
> lose sleep over.
>
> First, the orders database. It's still a file on the API server's own
> disk. Every lunch rush the API and the database fight over the same CPU
> and memory, and if that one box dies we lose orders. I want the orders in
> PostgreSQL, on its own server, on a private network where nothing on the
> internet can reach it and it can't reach the internet either. Only our API
> servers get in, and only over an encrypted connection.
>
> Second, menu photos. Right now they're in a folder on Bisi's laptop
> called `menu photos FINAL (2)`, and she emails them to whoever updates
> the menu. 😅 They belong in the `bukka-menu-photos` bucket from BUK-38,
> private and encrypted. The `Dish.photo_key` column in the API is already
> waiting for them.
>
> Thanks,
> Hussein

## Acceptance criteria

There are two halves, both on your machine, no AWS account and no bill:

- **The database** runs in Docker: a real PostgreSQL server on a private
  network, next to the API server from `labs/buk-45/`. This is how you
  would build it on your own servers, and it's what RDS does for you in
  AWS (see the table in `labs/buk-45/README.md`).
- **The AWS side** (the database's security group and the photos bucket)
  runs on **LocalStack**, like BUK-38 and BUK-42.

### Get the API server

1. Start it with `bash labs/buk-45/start.sh` and log in with
   `docker exec -it -u oncall bukka-api-1 bash`. Read the welcome message.
   The API works, but its data is a SQLite file on its own disk.

### A private network for the database

2. Create a Docker network called `bukka-db-net` with the `--internal`
   option, so nothing on it has a route to the internet.
3. Connect `bukka-api-1` to `bukka-db-net` as well. It stays on
   `bukka-web-net` too, so customers can still reach it.

### The database server

4. Run a PostgreSQL 16 container called `bukka-orders-db`:
   - image `postgres:16`
   - on `bukka-db-net` **only**
   - **no published ports** (no `-p`): nothing outside `bukka-db-net` can
     connect to it
   - database `bukka`, user `bukka`
   - data in a named volume called `bukka-orders-data`, so the orders
     survive the container being replaced
   - restarts by itself (`--restart unless-stopped`)
   - TLS turned on (`ssl=on`), so the API's connection can be encrypted.
     See the Notes
5. The password is at least 16 characters and is **not in any file you
   commit**. Your script reads it from an environment variable called
   `BUKKA_DB_PASSWORD` and refuses to run without it.
6. Save the commands for steps 2 to 4 in `infra/db/orders-db.sh`, so the
   database server can be rebuilt with one command.

### Point the API at it

7. On `bukka-api-1`, change `DATABASE_URL` in `/etc/bukka/api.env` to the
   new server, with TLS required:
   ```
   postgresql+psycopg://bukka:<password>@bukka-orders-db:5432/bukka?sslmode=require
   ```
8. Create the tables (`bukka-api migrate`), load the demo restaurants
   (`bukka-api seed`) and restart the API (`bukka-api restart`).
   `http://localhost:18082/readyz` returns `200` and
   `http://localhost:18082/api/restaurants` lists restaurants that now come
   from PostgreSQL.
9. Replace the database container (`docker rm -f bukka-orders-db`, then run
   your script again). The restaurants are still there.

### The AWS side (LocalStack)

10. Rebuild BUK-38 and BUK-42 on a fresh LocalStack with your scripts. Then
    create `bukka-web-sg` in `bukka-prod-vpc` (same rules as BUK-38; a
    security group belongs to one VPC).
11. Create a security group called `bukka-db-sg` in `bukka-prod-vpc` that
    allows TCP `5432` **only** from the `bukka-web-sg` security group (use
    the group as the source, not an IP range). No other inbound rules. This
    is the AWS version of what `bukka-db-net` does for you in Docker.
12. On `bukka-menu-photos-<your-github-username>`:
    - turn on **Block Public Access**, all four settings
    - turn on default encryption with **SSE-S3** (`AES256`)
    - upload at least three dish photos under the `dishes/` prefix, e.g.
      `dishes/mama-put-yaba/jollof-rice.jpg`. Any small images will do
13. Save these commands in `infra/cli/buk-45.sh`.

### Prove the database is private

14. In your pull request description, show the evidence:
    - `docker port bukka-orders-db` (it prints nothing)
    - `docker network inspect bukka-db-net --format '{{.Internal}}'`
    - a connection attempt from a container on `bukka-web-net` that **fails**,
      and the same attempt from `bukka-api-1` that **works**
      (`pg_isready -h <address> -p 5432`)
15. Add a short design note to the pull request description:
    - Why the database isn't simply on `bukka-web-net` with a strong password
    - Why `bukka-db-sg` uses a security group as the source instead of the
      API server's IP address
    - What `sslmode=require` protects against
    - What value `Dish.photo_key` should hold for a photo (the key, a URL,
      or something else?) and why

### Submit

16. Work on a branch called `buk-45-private-db-and-s3`, created from
    `upstream/apprentice/<your-github-username>`.
17. With LocalStack, `bukka-api-1` and `bukka-orders-db` all running, run
    `bash scripts/verify/buk-45.sh`. It writes
    `artifacts/buk-45-data-audit.txt`.
18. Commit `infra/` and the audit file, push, and open a pull request into
    `apprentice/<your-github-username>`, titled
    `feat: move orders to a private database and menu photos to S3 (BUK-45)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] No password appears anywhere in your commits (check `git log -p`)
- [ ] Amaka could read your evidence and agree the database is private

## Notes

- **Why a separate database server?** The API can be restarted, replaced or
  run as three copies; the data must outlive all of that. Once they're
  apart, each can be sized, backed up and secured for what it does. In AWS,
  RDS runs this server for you (backups, patching, failover), but the
  network rules are the same ones you set here.
- **Why no published port?** `-p 5432:5432` would put the database on your
  machine's network, and in the cloud, on the internet. Most database
  breaches start with a database that was reachable and a weak password.
  Unreachable beats strong.
- **Why `--internal`?** If someone does get into the database server, it
  can't download tools or send your customers' data anywhere. This is the
  "no route to the internet" from the BUK-42 database subnets.
- **TLS on the official image:** it already contains a test certificate.
  Add these to the end of your `docker run` command, after the image name:
  ```
  -c ssl=on -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem \
  -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
  ```
  In production you'd use a certificate from your own authority (RDS gives
  you one), and `sslmode=verify-full` to check it.
- **Passwords:** `openssl rand -base64 24 | tr -d '/+='` makes a good one.
  Keep it in your shell (`export BUKKA_DB_PASSWORD=...`) or a password
  manager. If it ever lands in a commit, it's leaked, even if you delete it
  later: change it.
- **Testing a connection from the web network:**
  ```bash
  docker run --rm --network bukka-web-net postgres:16 pg_isready -h <db-ip> -p 5432 -t 3
  ```
  Find the database's address with
  `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' bukka-orders-db`.
- **Starting LocalStack** (version pinned: newer images need a LocalStack
  account):
  ```bash
  docker run --rm -d --name localstack -p 4566:4566 \
    -v /var/run/docker.sock:/var/run/docker.sock localstack/localstack:4.14.0
  ```
- **Pointing the AWS CLI at it:**
  ```bash
  export AWS_ENDPOINT_URL=http://localhost:4566
  export AWS_ACCESS_KEY_ID=test
  export AWS_SECRET_ACCESS_KEY=test
  export AWS_DEFAULT_REGION=us-east-1
  ```
- Useful commands: `docker network create --internal`,
  `docker network connect`, `docker volume ls`, `docker logs bukka-orders-db`,
  `psql`, `aws ec2 authorize-security-group-ingress --source-group`,
  `aws s3api put-public-access-block`, `aws s3api put-bucket-encryption`,
  `aws s3 cp`, `aws s3 ls`.
- Windows: run everything from WSL. If Docker won't run on your machine, use
  a GitHub Codespace on your fork: Docker is already installed there.
