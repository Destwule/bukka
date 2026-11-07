# BUK-38: Give the API server read access to the menu-photos bucket

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-2 Move to the cloud |
| **Month** | 2 |
| **Sprint** | 5 |
| **Reporter** | Amaka (Security) |
| **Assignee** | You |
| **Due** | End of sprint 5 |

## Context

> Hi team 👋 Quick one from the security review before we put anything in
> AWS.
>
> Last week I found an AWS access key pasted into a `.env` file on
> bukka-prod-1 so the API could read menu photos. Anyone who gets on that
> box, or sees that file in a screenshot, can use that key from anywhere in
> the world, and it never expires. That can't follow us into the cloud.
>
> For the new API server I want three things: no keys on the machine at
> all, the server can **read** menu photos and nothing else, and only web
> traffic gets in from the internet. Also, finance asked me to make sure
> nobody wakes up to a surprise AWS bill, so please put an alarm on
> spending while you're there.
>
> Thanks,
> Amaka, Security

## Acceptance criteria

All of this runs on **LocalStack**, AWS simulated in Docker on your machine.
No AWS account, no credit card, no bill. See the Notes for setup.

### The bucket

1. Create an S3 bucket called `bukka-menu-photos-<your-github-username>`
   (all lowercase). It can be empty for now. BUK-45 locks it down and fills
   it.

### An identity for the server, not a key

2. Create an IAM role called `bukka-api-server-role` that only EC2 can use
   (its trust policy allows `ec2.amazonaws.com` and nothing else).
3. Attach a policy to the role that allows **only** reading from your
   bucket:
   - `s3:GetObject` on `arn:aws:s3:::bukka-menu-photos-<username>/*`
   - `s3:ListBucket` on `arn:aws:s3:::bukka-menu-photos-<username>`
   - No `*` actions, no `*` resources, no write or delete actions.
4. Create an instance profile called `bukka-api-server-profile` and add the
   role to it.

### The API server

5. Create a security group called `bukka-web-sg`:
   - TCP `80` and `443` open to `0.0.0.0/0`, so customers can reach the site.
   - TCP `22` (SSH) either not open at all, or open **only** to your own IP
     as a `/32`. Never to `0.0.0.0/0`.
   - No other inbound rules.
6. Launch one EC2 instance (`t3.micro`) tagged `Name=bukka-api-1`, with
   `bukka-web-sg` and the `bukka-api-server-profile` instance profile
   attached.
7. **No access keys anywhere.** Nothing starting with `AKIA` in your user
   data, your scripts or your commits.

### No surprise bills

8. Create an SNS topic called `bukka-billing-alerts` with your email
   subscribed to it.
9. Create a CloudWatch alarm called `bukka-spend-above-zero` on the
   `AWS/Billing` `EstimatedCharges` metric (currency `USD`) that fires when
   the charge goes above `0` and notifies `bukka-billing-alerts`.

### Write it down

10. Save every command you ran, in order, in `infra/cli/buk-38.sh`, so you
    (or a teammate) can rebuild all of this on a fresh LocalStack with one
    command. You will need this in BUK-42 and BUK-45.
11. In your pull request description, add a short design note (a few
    sentences each):
    - Why an instance profile is safer than a key in a `.env` file
    - What an attacker on the server could and couldn't do with this role
    - Why SSH is closed (or limited to your IP)

### Submit

12. Work on a branch called `buk-38-api-server-photo-access`, created from
    `upstream/apprentice/<your-github-username>`.
13. With LocalStack running and your resources created, run
    `bash scripts/verify/buk-38.sh`. It writes
    `artifacts/buk-38-iam-audit.txt`.
14. Commit the audit file and `infra/cli/buk-38.sh`, push, and open a pull
    request into `apprentice/<your-github-username>`, titled
    `feat: give the API server read-only access to menu photos (BUK-38)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] Your design note would convince Amaka that the old key problem can't
      happen again

## Notes

- **Why a role instead of a key?** A role gives the server short-lived
  credentials that AWS rotates for it every few hours. There is nothing to
  leak in a file, and if the server is retired the access goes with it.
- **Why so narrow?** If someone breaks into the API server, the role decides
  how much damage they can do. Read-only on one bucket means the worst case
  is someone looking at pictures of jollof, not deleting them or reading the
  rest of the account. This is called least privilege.
- **Why us-east-1?** AWS only publishes billing metrics in `us-east-1`, so
  we keep everything in that one region for now.
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
  aws sts get-caller-identity   # should answer from LocalStack
  ```
  `test` / `test` are LocalStack's dummy keys. They live in your shell only,
  never on the server and never in the repo.
- LocalStack forgets everything when it stops. That's why you save your
  commands in `infra/cli/buk-38.sh`: run it again and you're back. Run it on
  a fresh LocalStack: running it twice launches a second `bukka-api-1`, and
  the verify script expects exactly one.
- LocalStack accepts the AMI IDs it lists with `aws ec2 describe-images`.
  The instance is simulated, so you won't SSH into it. The verify script
  checks how it's configured.
- Useful commands: `aws iam create-role`, `aws iam put-role-policy`,
  `aws iam create-instance-profile`, `aws iam add-role-to-instance-profile`,
  `aws ec2 create-security-group`, `aws ec2 authorize-security-group-ingress`,
  `aws ec2 run-instances --iam-instance-profile`, `aws sns create-topic`,
  `aws cloudwatch put-metric-alarm`.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
