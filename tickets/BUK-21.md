# BUK-21: Menu page fails to load for customers

| | |
|---|---|
| **Type** | Bug |
| **Priority** | Highest |
| **Epic** | BUK-1 Platform foundations |
| **Month** | 1 |
| **Sprint** | 2 |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You (on call) |
| **Due** | End of the week |

## Context

### Why this matters

🚨 Since this morning, support has been flooded: customers say the app
"keeps loading" and the restaurant list never shows up, and a few got an
error page instead. Lunch orders are down sharply and two restaurant
partners have called asking if we're closed. Every hour this lasts costs our
partners real money, so this is the top priority for whoever is on call.

### What I need from you

- Last night someone changed bukka-prod-1 for the new security policy, and
  nobody is sure exactly what. Find out what's broken, using evidence, not
  guesses.
- Apt updates and outbound calls from the box have also been failing since
  the same change; treat that as part of the same incident.
- Fix it properly on the server, then write the runbook so the next person
  on call can fix it in five minutes.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

### Get on the server

1. Start the lab server with `bash labs/buk-21/start.sh` and log in as the
   on-call engineer: `docker exec -it -u oncall bukka-prod-1 bash`.
   Customers reach it at `http://localhost:18080`.

### Restore service

2. Customers can load the restaurant list from outside the server:
   `curl http://localhost:18080/api/restaurants` returns the restaurants.
3. Find and fix **every** cause. There is more than one, and fixing one
   reveals the next.
4. **Keep the server secure while you fix it.** The firewall must stay on
   with a default-deny policy. Open only what customers need.
5. The server can resolve DNS names again.
6. Your fixes must survive a restart of the API (`bukka-api restart`).

### Write it down

7. Add a runbook, `runbooks/menu-page-fails.md`, using the template in
   [runbooks/README.md](../runbooks/README.md). Explain:
   - the commands you used to narrow it down, and what each told you
   - what **"Connection refused"** told you, compared with a
     **connection that timed out**, and which fault caused each
   - how to tell, in under a minute, whether this has happened again

### Submit

8. Work on a branch called `buk-21-menu-page-fails`, created from
   `upstream/apprentice/<your-github-username>`.
9. With the server still running, run `bash scripts/verify/buk-21.sh`. It
   writes `artifacts/buk-21-triage.txt`.
10. Commit the audit file and your runbook, push, and open a pull request
    into `apprentice/<your-github-username>`, titled
    `fix: restore menu access on bukka-prod-1 (BUK-21)`.

## Definition of done

- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request
- [ ] Your runbook would let someone else fix this alone at 2am

## Notes

- **Work from the outside in.** Can you reach it at all? Is anything
  listening? On which address? Is something in between dropping traffic?
  Which layer you're at decides which tool you reach for.
- Tools you have on the server: `curl -v`, `ss -ltnp`, `ip addr`,
  `dig`, `getent hosts`, `cat /etc/resolv.conf`, `sudo iptables -L -n -v`,
  `bukka-api status|restart|logs`.
- The lab starts broken every time you run `start.sh`, so you can practise
  from scratch as often as you like.
- **Don't read the files in `labs/buk-21/`.** They contain the answer. The
  skill being tested is the method, not the fix.
- If Docker won't run on your machine, use a GitHub Codespace on your fork:
  Docker is already installed there.
