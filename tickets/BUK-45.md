# BUK-45: Move the orders database to private RDS and menu photos to S3

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
> First, the orders database. It still lives on bukka-prod-1 next to the
> API, with a public IP. Every lunch rush the API and Postgres fight over
> the same CPU and memory, and if that one box dies we lose orders. I want
> it on RDS, in the private database subnets, where only our API servers
> can talk to it, and over an encrypted connection.
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

All of this runs on **LocalStack**, AWS simulated in Docker on your machine.
No AWS account, no credit card, no bill. See the Notes for setup.

### Start from your earlier work

1. On a fresh LocalStack, run `infra/cli/buk-38.sh` and
   `infra/cli/buk-42.sh` to rebuild the bucket, the role and the network.
2. Security groups belong to one VPC, so the API server needs to move into
   the new one. Create `bukka-web-sg` in `bukka-prod-vpc` (same rules as
   BUK-38), and launch `bukka-api-1` in `bukka-web-a` with that group and
   the `bukka-api-server-profile` instance profile. Update
   `infra/cli/buk-38.sh` if it helps.

### A private database

3. Create a DB subnet group called `bukka-db-subnets` using **only**
   `bukka-db-a` and `bukka-db-b`.
4. Create a security group called `bukka-db-sg` in `bukka-prod-vpc` that
   allows TCP `5432` **only** from the `bukka-web-sg` security group (use the
   group as the source, not an IP range). No other inbound rules.
5. Create an RDS PostgreSQL instance:
   - identifier `bukka-orders-db`, class `db.t3.micro`, 20 GB storage
   - database name `bukka`, master username `bukka`
   - in `bukka-db-subnets`, with `bukka-db-sg` attached
   - **not** publicly accessible
   - storage encrypted
6. The master password is not in any file you commit. Read it from an
   environment variable in your script (e.g. `BUKKA_DB_PASSWORD`).

### Point the API at it

7. Build the API's `DATABASE_URL` from the RDS endpoint, using TLS:
   ```
   postgresql+psycopg://bukka:<password>@<endpoint>:<port>/bukka?sslmode=require
   ```
8. With that `DATABASE_URL`, run the migrations
   (`.venv/bin/alembic upgrade head`) and load the demo restaurants
   (`.venv/bin/python -m bukka_api.seed`).
9. Start the API with the same `DATABASE_URL`. `GET /readyz` returns `200`
   and `GET /api/restaurants` lists the restaurants from RDS.

### Menu photos in S3

10. Turn on **Block Public Access** on `bukka-menu-photos-<username>`, all
    four settings.
11. Turn on default encryption with **SSE-S3** (`AES256`).
12. Upload at least three dish photos under the `dishes/` prefix, e.g.
    `dishes/mama-put/jollof-rice.jpg`. Any small images will do.

### Prove the database is private

13. In your pull request description, show the evidence that nobody on the
    internet can reach the database: the output of
    `aws rds describe-db-instances` showing `PubliclyAccessible: false`, the
    inbound rules of `bukka-db-sg`, and the route table of the database
    subnets.
14. Add a short design note to the pull request description:
    - What a connection attempt from the internet would do in real AWS,
      and whether you'd expect "Connection refused" or a timeout (think back
      to BUK-21)
    - Why the database rule uses a security group as the source instead of
      the API server's IP address
    - What `sslmode=require` protects against
    - What value `Dish.photo_key` should hold for a photo (the key, a URL,
      or something else?) and why

### Submit

15. Save the new commands in `infra/cli/buk-45.sh`. Never put the password
    in it.
16. Work on a branch called `buk-45-private-rds-and-s3`, created from
    `upstream/apprentice/<your-github-username>`.
17. With LocalStack running and the API connected to RDS, run
    `bash scripts/verify/buk-45.sh`. It writes
    `artifacts/buk-45-data-audit.txt`.
18. Commit the audit file and your scripts, push, and open a pull request
    into `apprentice/<your-github-username>`, titled
    `feat: move orders database to private RDS and menu photos to S3 (BUK-45)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] No password appears anywhere in your commits (check `git log -p`)
- [ ] Amaka could read your evidence and agree the database is private

## Notes

- **Why RDS?** AWS runs Postgres for us: backups, patching and disk
  replacement. We get to spend lunch rush watching orders, not the
  database server.
- **Why security group as the source?** Any server in `bukka-web-sg` can
  reach the database, now or after we add a second API server, and nothing
  else can. IP addresses change; group membership is what you actually
  mean.
- **Why Block Public Access?** Most "company leaks customer data from S3"
  stories are one wrong bucket setting. Block Public Access is the switch
  that overrides those mistakes. The API reads photos with its role from
  BUK-38, so the bucket never needs to be public.
- **About LocalStack and networks.** LocalStack keeps track of your VPC,
  subnets and security groups, but it doesn't enforce them like real AWS
  does. Its Postgres is reachable from your laptop on the port in the RDS
  endpoint (usually somewhere in `4510-4559`, not `5432`). That's why you
  run the API and the migrations from your machine here, and why the proof
  in step 13 is the configuration, not a failed connection. In real AWS
  you'd run them from `bukka-api-1`.
- **Starting LocalStack:**
  ```bash
  docker run --rm -d --name localstack -p 4566:4566 -p 4510-4559:4510-4559 \
    -v /var/run/docker.sock:/var/run/docker.sock localstack/localstack
  ```
- **Pointing the AWS CLI at it:**
  ```bash
  export AWS_ENDPOINT_URL=http://localhost:4566
  export AWS_ACCESS_KEY_ID=test
  export AWS_SECRET_ACCESS_KEY=test
  export AWS_DEFAULT_REGION=us-east-1
  ```
- Creating a database takes a little while. `aws rds wait
  db-instance-available --db-instance-identifier bukka-orders-db` waits for
  you.
- Useful commands: `aws rds create-db-subnet-group`,
  `aws rds create-db-instance`, `aws rds describe-db-instances`,
  `aws ec2 authorize-security-group-ingress --source-group`,
  `aws s3api put-public-access-block`, `aws s3api put-bucket-encryption`,
  `aws s3 cp`, `aws s3 ls`.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
