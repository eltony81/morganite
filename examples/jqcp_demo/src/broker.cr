require "morganite"
require "morganite/cli"

# Registered so the class name exists if this process's own native fetch
# loop (its `--queue`, separate from whatever queue the JQCP tutorial's
# Producer/Worker use) ever happens to claim a job — see
# docs/jqcp_tutorial.md for why the tutorial deliberately uses a different
# queue name for its JQCP traffic.
class JqcpDemoWorker
  include Morganite::Worker

  def perform(args)
  end
end

Morganite::CLI.run
