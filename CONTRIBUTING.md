# Contributing to Lamplight

Thanks for helping. Lamplight is meant to stay small: one menu, no windows, no network.

## Getting set up

```sh
git clone https://github.com/Wu-Adam1234/lamplight.git
cd lamplight
make test
make app && open dist/Lamplight.app
```

## Ground rules

- **Logic goes in `LamplightCore`** and gets a unit test. `Sources/Lamplight` should only glue
  that logic to AppKit and IOKit.
- **Anything touching the sudoers rule or `pmset`** needs a test, plus a note in the pull request
  explaining why it's safe. See [SECURITY.md](SECURITY.md).
- **Sleep must always come back.** Every path that ends a session (turn off, timer, battery, quit,
  signal) has to restore normal sleep. If you add a new path, test it by hand with
  `pmset -g | grep SleepDisabled`.
- **Menu text** uses Apple's title case for commands and plain sentences for status lines.
  No exclamation marks.
- No analytics, no network calls, no new dependencies without a good reason.

## Pull requests

1. Branch from `main`.
2. `make test` passes.
3. Describe what you changed and how you checked it on a real Mac (lid open and closed, if relevant).
