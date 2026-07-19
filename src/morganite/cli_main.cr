require "./cli"

# This is the shard's own `bin/morganite` entrypoint (see shard.yml's
# `targets.morganite.main`). `cli.cr` used to self-invoke via a
# `PROGRAM_NAME`-matching guard at its own bottom, but that was fragile in a
# way that actively bit real usage: a consuming app that requires
# "morganite/cli" *before* its own worker files (exactly the order this
# project's own docs/usage.md recommends) and whose binary happens to be
# named "morganite" (e.g. Docker's `ENTRYPOINT ["morganite"]`, also
# recommended in the same docs) would have the guard fire the instant
# `require "morganite/cli"` runs — before any worker class further down the
# file got a chance to register itself. Explicit invocation, here and in
# every consuming app, has no such ordering hazard.
Morganite::CLI.run
