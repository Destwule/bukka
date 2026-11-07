# BUK-14: Set up workstation and repository access

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-1 Platform foundations |
| **Month** | 1 |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of your first week |

## Context

### Why this matters

Welcome to the Bukka platform team! 👋 Every restaurant partner and every
hungry customer depends on what this team runs. Before you change anything
that touches production, we need to know who you are in the repo and trust
how your machine connects to it.

### What I need from you

- Join the team in the repo, so you get your own `apprentice/<username>` branch.
- Work as a normal user with `sudo`, not as root, the way we do on every server.
- Connect to GitHub with an SSH key, not a password.

Every ticket after this one assumes all three are in place.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

### Part 1: Join the team

1. Fork `alamz-tech/bukka` to your GitHub account.
2. Add `team/<your-github-username>.md` using the template in
   [team/README.md](../team/README.md). The file name must match your GitHub
   username exactly.
3. Open a pull request from a branch called `buk-14-join-team` into **`main`**
   of `alamz-tech/bukka`, titled `docs: add <your name> to the team (BUK-14)`.
4. Once it's merged, your branch `apprentice/<your-github-username>` appears
   in `alamz-tech/bukka` within a minute or two.

Part 1 is the quickest way into the repo, so you can do it in the GitHub
website. Part 2 must be done on your machine.

### Part 2: Secure workstation

Use Linux, macOS, or WSL on Windows. If you can't install anything locally,
use a GitHub Codespace on your fork.

1. **Work as a normal user, not root**, and make sure that user can use
   `sudo` for admin tasks.
2. **Create an SSH key** (`ed25519`) with a passphrase. The private key must
   be readable only by you (`600` or `400`), and `~/.ssh` must be `700`.
3. **Add the public key to your GitHub account.** `ssh -T git@github.com`
   must greet you by your username.
4. **Set your Git identity** with your real name and the email on your GitHub
   account (`git config --global user.name` / `user.email`).
5. **Clone your fork over SSH** and add `alamz-tech/bukka` as a remote called
   `upstream` (see [CONTRIBUTING.md](../CONTRIBUTING.md#1-one-time-setup)).
6. Create a branch called `buk-14-workstation-setup` from
   `upstream/apprentice/<your-github-username>`.
7. **Run the verify script** from the repo root:
   ```bash
   bash scripts/verify/buk-14.sh
   ```
   It checks everything above and writes `artifacts/workstation-audit.txt`.
8. Commit that file with the message
   `chore: set up secure workstation and SSH access (BUK-14)`, push, and open
   a pull request into **`apprentice/<your-github-username>`**.

## Definition of done

- [ ] Your team file is merged into `main` and your `apprentice/` branch exists
- [ ] The verify script passes on your machine
- [ ] Your Part 2 pull request passes the `verify` check
- [ ] A teammate has reviewed your Part 2 pull request

## Notes

- **Why not root?** One wrong command as root can wipe a server. On real
  production machines you log in as yourself and use `sudo` only when you
  must, which also leaves a record of who did what.
- **Why SSH keys?** GitHub stopped accepting passwords for Git in 2021. A key
  can be revoked on its own without changing your password, and the
  passphrase protects it if your laptop is stolen.
- **Why does the file name matter?** The automation that creates your branch
  reads your GitHub username from the file name, and CI checks that your
  pull requests target your own branch.
- Useful commands: `whoami`, `id`, `sudo -v`, `ssh-keygen -t ed25519 -C "<email>"`,
  `chmod`, `ls -la ~/.ssh`, `git remote -v`.
