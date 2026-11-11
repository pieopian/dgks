# dgks tests

These tests run `dgks.lua` under plain Lua 5.1, without the game, against a small simulation of
the WoW addon API. They are run automatically on every push and pull request
(`.github/workflows/tests.yml`).

## Run them

From the repository root, with Lua 5.1 installed:

```
lua5.1 tests/run_tests.lua .
```

The exit code is the number of failed tests.

## Files

- `wow_shim.lua` simulates the client: frames and events, timers, units and GUIDs, chat and addon
  messages, Battle.net friends, console variables, and secret values. It records every sound,
  addon message, print and text output so a test can check what the addon did. It loads the real
  LibStub and AceSerializer from `libs/` and replaces the other libraries with minimal stand-ins.
- `run_tests.lua` holds the tests. Each one loads a fresh copy of the addon, fires events at it
  (`W.fire("PARTY_KILL", attackerGUID, targetGUID)`) and returns `true` if the result is right.

## What they cover

Loading, the release build (debug blocks stripped the way the packager does it), kill and
multikill detection on the Retail 12 / WoW Forever event path, broadcasts in and out, and duels.

## Limits

- Plain Lua cannot make a comparison on a simulated secret value throw the way the client does, so
  the tests can show that a secret value is ignored, not that it is never compared.
- Whether a message is really delivered, and what the client sends inside dungeons and
  battlegrounds, can only be seen in game.
- AceComm, AceDB and the options UI are stand-ins; the tests do not exercise the real libraries.
