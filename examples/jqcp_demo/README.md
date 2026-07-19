# JQCP Demo Broker

Minimal Broker app for [`docs/jqcp_tutorial.md`](../../docs/jqcp_tutorial.md)
— a single registered worker class plus `Morganite::CLI.run`. Producer,
Worker, and Operator are all played by plain `curl` calls in the tutorial
itself, not by code in this app.

```bash
shards install
crystal build src/broker.cr -o bin/broker

export MORGANITE_REDIS_URL=redis://localhost:6379/0
export MORGANITE_QUEUE=default
export MORGANITE_WEB_PORT=7420
export MORGANITE_JQCP_WORKER_TOKEN=worker-secret
export MORGANITE_JQCP_OPERATOR_READ_TOKEN=read-secret
export MORGANITE_JQCP_OPERATOR_WRITE_TOKEN=write-secret

./bin/broker
```

Then follow the tutorial from step 2 onward.
