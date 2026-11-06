# BUK-42: Create the production network with public and private subnets

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-2 Move to the cloud |
| **Month** | 2 |
| **Sprint** | 6 |
| **Reporter** | Hussein (Engineering Lead) |
| **Assignee** | You |
| **Due** | End of sprint 6 |

## Context

> Nice work on BUK-38. Next up is the thing that worries me most.
>
> Right now the orders database runs on bukka-prod-1, and that box has a
> public IP. Amaka's scan found Postgres answering on 5432 from the
> internet. The only thing between every customer's address and phone
> number and the whole world is one password. That has to end before we
> move the database to AWS.
>
> So before anything else moves, I want a proper network for production:
> one part the internet can reach for the website and API, and a separate
> part for the database that has no road to the internet at all. Build it
> across two availability zones, because the managed database we're moving
> to in BUK-45 needs that, and because a single data centre having a bad
> day at lunchtime shouldn't take all of Bukka down with it.
>
> Thanks,
> Hussein

## Acceptance criteria

All of this runs on **LocalStack**, AWS simulated in Docker on your machine.
No AWS account, no credit card, no bill. See the Notes for setup.

### The VPC

1. Create a VPC tagged `Name=bukka-prod-vpc` with the CIDR block
   `10.0.0.0/16`.

### Subnets in two availability zones

2. Create four subnets, tagged with `Name` and `Tier` exactly as below:

   | Name | CIDR | Availability zone | Tier |
   |---|---|---|---|
   | `bukka-web-a` | `10.0.1.0/24` | `us-east-1a` | `public` |
   | `bukka-web-b` | `10.0.2.0/24` | `us-east-1b` | `public` |
   | `bukka-db-a` | `10.0.10.0/24` | `us-east-1a` | `private` |
   | `bukka-db-b` | `10.0.20.0/24` | `us-east-1b` | `private` |

3. The web subnets give new instances a public IP automatically
   (`MapPublicIpOnLaunch` is `true`). The database subnets don't.

### Routing

4. Create an internet gateway tagged `Name=bukka-prod-igw` and attach it to
   `bukka-prod-vpc`.
5. Create a route table tagged `Name=bukka-public-rt` with a route for
   `0.0.0.0/0` to the internet gateway. Associate it with both web subnets.
6. Create a route table tagged `Name=bukka-private-rt` with **no** route to
   the internet gateway (only the built-in `local` route). Associate it with
   both database subnets.
7. No route table in the VPC sends database subnet traffic to the internet.
   Check the VPC's main route table too.

### Write it down

8. Save every command you ran, in order, in `infra/cli/buk-42.sh`, so the
   network can be rebuilt on a fresh LocalStack with one command.
9. In your pull request description, add:
   - A simple diagram of the network (ASCII art or a picture is fine) showing
     the VPC, the four subnets, both route tables and the internet gateway
   - A short design note: why the database subnets have no internet route,
     why we use two availability zones, and what would change if the
     database ever needed to download updates from the internet (hint: look
     up NAT gateways, and what they cost)

### Submit

10. Work on a branch called `buk-42-production-network`, created from
    `upstream/apprentice/<your-github-username>`.
11. With LocalStack running and your network created, run
    `bash scripts/verify/buk-42.sh`. It writes
    `artifacts/buk-42-network-audit.txt`.
12. Commit the audit file and `infra/cli/buk-42.sh`, push, and open a pull
    request into `apprentice/<your-github-username>`, titled
    `feat: create production VPC with public and private subnets (BUK-42)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] A teammate could look at your diagram and say which subnet a new
      server belongs in

## Notes

- **What makes a subnet "public"?** Nothing about the subnet itself. It's
  public because its route table sends `0.0.0.0/0` to an internet gateway.
  Take that route away and the same subnet is private. That's why the route
  tables are the most important part of this ticket.
- **Why `/16` and `/24`?** `10.0.0.0/16` gives the VPC about 65,000
  addresses to grow into. Each `/24` subnet has 256 (AWS keeps 5 of them).
  Leaving gaps like `10.0.3.0` to `10.0.9.0` means there's room for more web
  subnets later without renumbering.
- **Why two availability zones?** An availability zone is a separate data
  centre in the same region. AWS requires a database subnet group to cover
  at least two of them, and it means one data centre failing doesn't have
  to mean Bukka is down.
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
- LocalStack forgets everything when it stops, so keep `infra/cli/buk-42.sh`
  up to date. Tip: capture IDs into variables as you go, e.g.
  `VPC_ID=$(aws ec2 create-vpc ... --query Vpc.VpcId --output text)`.
- Useful commands: `aws ec2 create-vpc`, `aws ec2 create-subnet`,
  `aws ec2 modify-subnet-attribute --map-public-ip-on-launch`,
  `aws ec2 create-internet-gateway`, `aws ec2 attach-internet-gateway`,
  `aws ec2 create-route-table`, `aws ec2 create-route`,
  `aws ec2 associate-route-table`, `aws ec2 create-tags`,
  `aws ec2 describe-route-tables --filters Name=vpc-id,Values=<id>`.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
