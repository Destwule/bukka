# BUK-51: Manage production infrastructure with Terraform

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-2 Move to the cloud |
| **Month** | 2 |
| **Sprint** | 8 |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of sprint 8 |

## Context

### Why this matters

We're about to onboard a lot more restaurants, and our infrastructure is
three shell scripts nobody fully trusts. Last week someone ran `buk-42.sh`
twice and ended up with two VPCs. Nobody can look at a script and say what
production *should* look like, or what a change will do before it happens.
That's how outages and surprise bills start.

### What I need from you

- From now on production is code. Everything from BUK-38, BUK-42 and the AWS
  side of BUK-45 goes into Terraform, in modules (network, compute, database,
  storage, billing) that can be reviewed on their own.
- State lives in a shared, locked bucket, not on a laptop.
- Every change gets a plan that a teammate reads in the pull request before
  anyone applies it.
- Prove it works from scratch: tear the whole thing down and build it again.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

All of this runs on **LocalStack**, AWS simulated in Docker on your machine.
No AWS account, no credit card, no bill. See the Notes for setup.

### Project layout

1. Put the Terraform code in `infra/terraform/`, laid out like this:
   ```
   infra/terraform/
     versions.tf      Terraform and AWS provider version constraints
     backend.tf       remote state
     main.tf          calls the modules and wires them together
     variables.tf     inputs, each with a type and a description
     outputs.tf       VPC ID, API server ID, bukka-db-sg ID, bucket name
     modules/
       network/       VPC, subnets, internet gateway, route tables (BUK-42)
       compute/       IAM role and instance profile, bukka-web-sg, bukka-api-1 (BUK-38)
       database/      bukka-db-sg (BUK-45)
       storage/       menu photos bucket, Block Public Access, SSE-S3 (BUK-45)
       billing/       SNS topic and the spend alarm (BUK-38)
   ```
2. Every module has its own `main.tf`, `variables.tf` and `outputs.tf`.
3. Modules don't hard-code each other's IDs. The root `main.tf` passes
   outputs from one module into another (e.g. the network module's subnet
   IDs into the database module).

### Same rules as before

4. Everything the verify scripts for BUK-38, BUK-42 and BUK-45 checked
   still holds: the same names, CIDRs and tags, read-only access to one
   bucket, `5432` only from `bukka-web-sg`, no route from the database
   subnets to the internet, Block Public Access and SSE-S3 on the bucket.
5. No secrets in the code: no passwords and no access keys anywhere.
   The database server itself stays in `infra/db/orders-db.sh` from
   BUK-45 (Terraform manages the AWS side only).

### Remote state

6. Store state in an S3 bucket called `bukka-tfstate-<your-github-username>`
   with versioning and encryption on, using S3 state locking
   (`use_lockfile = true`). Create this one bucket by hand (or with a small
   script) before `terraform init`.
7. No state files, `.terraform/` directories or `.tfvars` files with
   secrets are committed. Add them to `.gitignore`. Do commit
   `.terraform.lock.hcl`.

### Plan, review, apply, destroy

8. `terraform fmt -check -recursive` and `terraform validate` both pass.
9. On a fresh LocalStack, run `terraform plan` and paste the plan summary
   (the list of resources and the `Plan: N to add` line) into your pull
   request description. A teammate reviews the plan, not just the code.
10. `terraform apply` builds everything in one go, with no errors.
11. Running `terraform plan` again straight after shows **No changes**.
12. `terraform destroy` removes everything cleanly, and a second
    `terraform apply` builds it all again.
13. Remove `infra/cli/buk-38.sh`, `buk-42.sh` and `buk-45.sh`. Terraform is
    now the only way the AWS side is built. Keep `infra/db/orders-db.sh`.

### Write it down

14. Add a short design note to your pull request description:
    - Why you split the modules the way you did, and what each one outputs
    - Why state lives in S3 and not on your laptop, and why it needs
      locking
    - Why state files are treated as secrets: look inside yours, and say
      what would end up there if Terraform also created the database
      password

### Submit

15. Work on a branch called `buk-51-terraform-production`, created from
    `upstream/apprentice/<your-github-username>`.
16. With LocalStack running and the stack applied, run
    `bash scripts/verify/buk-51.sh`. It writes
    `artifacts/buk-51-terraform-audit.txt`.
17. Commit the audit file and your Terraform code, push, and open a pull
    request into `apprentice/<your-github-username>`, titled
    `feat: manage production infrastructure with Terraform (BUK-51)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed your plan output and approved your pull
      request
- [ ] You have destroyed and rebuilt the whole stack at least once
- [ ] A teammate could clone your branch and build production with
      `terraform init` and `terraform apply`

## Notes

- **Why Terraform?** A script says *how* to build something. Terraform
  says *what* should exist, works out the difference from what does exist,
  and shows you that difference as a plan. Running it twice doesn't give
  you two VPCs.
- **Why review the plan?** Code that looks harmless can still replace a
  database. The plan says `must be replaced` in plain words. Reading it
  before apply is the habit that saves you.
- **Why remote state?** State is Terraform's memory of what it built. On
  one laptop it's lost when the laptop is, and two people applying at once
  can corrupt it. A shared, versioned, locked bucket fixes both.
- **Starting LocalStack** (version pinned: newer images need a LocalStack
  account):
  ```bash
  docker run --rm -d --name localstack -p 4566:4566 \
    -v /var/run/docker.sock:/var/run/docker.sock localstack/localstack:4.14.0
  ```
- **Pointing Terraform at it:**
  ```bash
  export AWS_ENDPOINT_URL=http://localhost:4566
  export AWS_ACCESS_KEY_ID=test
  export AWS_SECRET_ACCESS_KEY=test
  export AWS_DEFAULT_REGION=us-east-1
  ```
  Then, in the provider block, add `s3_use_path_style = true`,
  `skip_credentials_validation = true` and
  `skip_requesting_account_id = true`. For the backend, keep the LocalStack
  settings in a separate file and pass it at init, so `backend.tf` stays
  the same for real AWS:
  ```hcl
  # backend-localstack.hcl
  endpoints                   = { s3 = "http://localhost:4566" }
  use_path_style              = true
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  ```
  ```bash
  terraform init -backend-config=backend-localstack.hcl
  ```
  `tflocal` (from `pip install terraform-local`) can do this wiring for
  you if you prefer.
- Start small: get the network module planning and applying first, then
  add one module at a time.
- Useful commands: `terraform init`, `terraform fmt -recursive`,
  `terraform validate`, `terraform plan`, `terraform apply`,
  `terraform state list`, `terraform output`, `terraform destroy`.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
