# BUK-63: Add a CI pipeline that tests, builds and publishes images

| | |
|---|---|
| **Type** | Task |
| **Priority** | High |
| **Epic** | BUK-3 Containers and continuous delivery |
| **Month** | 3 |
| **Sprint** | 10 |
| **Reporter** | Hussein Alamutu (Product Manager & Lead DevOps Engineer) |
| **Assignee** | You |
| **Due** | End of Sprint 10 |

## Context

### Why this matters

Last Friday someone built the API image on their laptop, tagged it `latest`
and pushed it, with a half-finished change inside. When the kitchen screen
started showing orders twice during lunch, nobody could say which code was
running, because `latest` had been overwritten twice that morning. We rolled
back by guessing. 🙈

### What I need from you

- Images are built by CI, not by people.
- Every pull request is tested and linted before anyone reviews it.
- Every image we publish is tagged with the commit it was built from: if I
  see an image, I want to find the exact code behind it in ten seconds.
- BUK-58 gave us the Dockerfiles; this ticket turns them into a pipeline.

— Hussein Alamutu, Product Manager & Lead DevOps Engineer

## Acceptance criteria

### The pipeline

1. Add `.github/workflows/ci.yml`. The team's existing `app.yml` only runs
   the tests. Yours goes further and is the one we'll rely on.
2. It runs on **every pull request**, and on **every push to `main`** and
   to your `buk-*` branches in your fork.
3. Give the workflow only the permissions it needs: `contents: read` by
   default, and `packages: write` only on the job that publishes images.

### Quality gates

4. **API tests:** install the API and run `pytest`. A failing test fails
   the pipeline.
5. **Web build:** `npm ci` and `npm run build` in `web/`. A broken build
   fails the pipeline.
6. **Lint the shell scripts** with `shellcheck`. Any warning fails the
   pipeline. Fix the warnings rather than turning the rule off, unless you
   can explain why in your design note.
7. **Lint every Dockerfile** with `hadolint`, with the same rule.
8. The image build only starts once all the checks above pass.

### Build and publish the images

9. Build the `web`, `api` and worker images from your BUK-58 Dockerfiles
   (or `web` and `api`, if your worker reuses the API image).
10. **Tag every image with the git commit SHA**, for example
    `ghcr.io/<your-github-username>/bukka-api:sha-3f9c2ab`. You may add
    other tags too, such as the branch name, but never publish `latest` on
    its own.
11. **Publish to GitHub Container Registry (GHCR)** using the built-in
    `GITHUB_TOKEN`. No personal access tokens and no passwords in the
    workflow.
12. **Publish only on a push**, never from a pull request. Pull requests
    build the images to prove they still build, then stop.
13. Make the packages **public** in your GitHub settings so the cluster in
    BUK-70 can pull them without a password.

### Prove it catches problems

14. Push a commit that breaks one API test. Copy the link to the red run,
    then revert the commit and get the pipeline green again.

### Submit

15. Work on a branch called `buk-63-ci-pipeline`, created from
    `upstream/apprentice/<your-github-username>`.
16. Once a run on your fork is green and the images are published, run
    `bash scripts/verify/buk-63.sh`. It writes
    `artifacts/buk-63-ci.txt`.
17. Commit the workflow, any lint fixes and the audit file, push, and open
    a pull request into `apprentice/<your-github-username>`, titled
    `ci: test, build and publish images on every change (BUK-63)`.
18. In the pull request description, add a short **design note**:
    - links to one green run and the red run from step 14
    - the full name and tag of one image you published, and how you'd find
      the commit it was built from
    - why the pipeline doesn't publish images from pull requests

## Definition of done

- [ ] Your pipeline is green on your pull request
- [ ] Images tagged with a commit SHA are visible on your GitHub profile under **Packages**
- [ ] `verify` passes on your pull request
- [ ] A teammate has reviewed and approved your pull request

## Notes

- **Why the commit SHA?** A SHA points to exactly one version of the code,
  forever. `latest` points to whatever was pushed last, which is how we
  ended up guessing on Friday. Tags like `latest` or `main` are fine as
  extras, as long as the SHA tag is always there too.
- **Why not publish from pull requests?** Code in a pull request hasn't been
  reviewed yet. Also, pull requests from a fork get a read-only
  `GITHUB_TOKEN`, so a push to the registry from one would fail anyway.
- **Why lint Dockerfiles?** `hadolint` catches the mistakes that make images
  big, slow or unsafe: unpinned versions, leftover package caches, running
  as root.
- A good shape for the workflow is a few small jobs (`test-api`,
  `build-web`, `lint`) and one `images` job that `needs:` all of them.
- Useful actions: `actions/checkout`, `actions/setup-python`,
  `actions/setup-node`, `docker/login-action`, `docker/build-push-action`,
  `docker/metadata-action` (it can make the `sha-` tag for you).
- GHCR image names must be lowercase. If your GitHub username has capital
  letters, lowercase it in the image name.
- Your first workflow run on the team repo may wait for a maintainer to
  approve it. That's a GitHub safety feature for fork pull requests, not a
  problem with your pipeline.
