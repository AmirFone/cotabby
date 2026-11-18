#!/usr/bin/env python3
"""Builds the two software-engineering word lists in Cotabby/Resources.

The frequency dictionary is general English. It has `server` and `database` but not `backend`,
`config`, `repo`, `async`, `kubectl` or `jsonb`, and it counts `docker` and `refactor` as rare words.
For someone who writes about software all day that means the strip never offers the word they are
typing and the spelling engine flags it, or "fixes" it to an ordinary word.

`technical_words_en.txt` is for the word strip. Each line is `word count [Conventional]`: the word
in lowercase, a count on the dictionary's scale, and the usual capitals when they differ
(`json 3000000 JSON`). The counts are three tiers set by hand, not measured in a corpus: words an
engineer uses daily, weekly, and now and then. Where the dictionary also has the word, the app uses
the larger count. The capitals are left out for a term that is also an ordinary English word
(`swift`, `spring`, `react`, `rust`), or the strip would capitalize it in every sentence; a few
names the dictionary happens to list in lowercase (`linux`, `python`) keep theirs.

`technical_spelling_en.txt` is for the spelling dictionary: the terms the dictionary lacks, of five
letters or more, plus a handful of four-letter ones engineers type constantly. It is stricter
because the risk is different. A short term in the spelling dictionary makes a slip that happens to
spell it look right (`aws` for `was`, `util` for `until`, `iam` for `I am`), and raising the count of
a word the dictionary already has would change which ordinary word a slip is fixed to.

Only single words made of letters go in: the word under the caret is found by its letters, so
`k8s`, `oauth2` and `read-only` could never be matched.

Usage:
  python3 -I Tools/prediction/build_technical_words.py Cotabby/Resources/frequency_dictionary_en_82_765.txt \
      Cotabby/Resources/technical_words_en.txt Cotabby/Resources/technical_spelling_en.txt
"""
import sys

DAILY, WEEKLY, SOMETIMES = 3_000_000, 800_000, 200_000

TERMS = {
    DAILY: """
        API APIs JSON YAML SQL HTML CSS HTTP HTTPS URL URLs UI UX CLI SDK IDE CPU GPU
        backend frontend fullstack config configs repo repos codebase async await sync endpoint endpoints
        payload middleware runtime boolean enum enums struct structs namespace regex refactor refactored
        refactoring linter lint localhost timeout timeouts webhook webhooks plugin plugins dataset datasets
        GitHub GitLab Docker Kubernetes Postgres PostgreSQL MySQL Redis Kafka AWS Linux macOS iOS Android
        JavaScript TypeScript Python Java Kotlin Swift Golang Rust Ruby PHP Node React
        git commit commits rebase merge merged branch branches rollback rollout deploy deployed deployment
        deployments hotfix changelog cron sudo grep bash zsh npm yarn pip
        database databases schema schemas query queries index indexes cache cached caching queue queues
        thread threads mutex latency throughput scalable scalability
        bug bugs bugfix debug debugging debugger stacktrace breakpoint logging logs
        param params args arg env var vars util utils init auth authn authz login logout signup
        username hostname filename filepath pathname timestamp timestamps metadata checksum
        parse parser parsing serialize serialized deserialize tokenizer tokenize
        microservice microservices monolith monorepo serverless container containers containerized
        upstream downstream dependency dependencies changeset pipeline pipelines workflow workflows
        dashboard dashboards frontmatter markdown readme docs docstring
    """,
    WEEKLY: """
        XML CSV TSV PDF PNG SVG JWT OAuth SSO SAML SSH TLS SSL DNS CDN VPN VPC TCP UDP REST RPC gRPC GraphQL
        CRUD ORM ETL ELT SLA SLO SLI KPI IAM RDS SQS SNS EKS ECS GKE AKS NAT CORS CSRF XSS DDoS LDAP
        SaaS PaaS IaaS DevOps MLOps SRE QA
        jsonb varchar bigint nullable upsert upserts backfill backfilled sharding shard shards replica replicas
        failover idempotent idempotency atomicity denormalized denormalize normalization partitioning partitioned
        deduplicate deduplication dedupe materialized
        kubectl kubelet Helm Terraform Ansible Jenkins Grafana Prometheus Datadog Splunk Kibana Elasticsearch
        Nginx Apache Tomcat RabbitMQ MongoDB DynamoDB Cassandra SQLite Snowflake Databricks BigQuery Redshift
        Airflow Spark Hadoop Flink Hive Presto Trino dbt Tableau Looker
        Azure GCP Heroku Vercel Netlify Cloudflare Lambda Fargate
        Jira Confluence Slack Figma Postman Swagger OpenAPI Bitbucket Xcode Gradle Maven Webpack Vite Babel ESLint
        Prettier Pytest JUnit Jest Cypress Selenium Playwright
        Django Flask FastAPI Rails Spring Laravel Express Angular Vue Svelte Tailwind Bootstrap jQuery
        NumPy pandas PyTorch TensorFlow Jupyter
        Dockerfile Makefile gitignore dotfile dotfiles symlink symlinks chmod chown stdin stdout stderr
        iterator iterators iterable generics polymorphism inheritance encapsulation immutable immutability
        mutable nullability nullable singleton getter getters setter setters callback callbacks closure closures
        coroutine coroutines goroutine goroutines semaphore deadlock deadlocks multithreading multithreaded
        concurrency parallelism asynchronous synchronous blocking nonblocking
        hashmap hashtable tuple tuples dict dicts substring substrings bitmask bitwise bytecode
        allocator deallocate malloc dereference pointer pointers typedef
        compiler compilers interpreter transpile transpiler bundler minify minified obfuscate
        linting typecheck typechecking typesafe autocomplete autocompletion intellisense
        unittest unittests mock mocks mocking stub stubs fixture fixtures assertion assertions
        regression regressions flaky benchmark benchmarks benchmarking profiler profiling
        autoscaling autoscale loadbalancer proxy proxies gateway failback healthcheck healthchecks
        heartbeat uptime downtime outage outages postmortem runbook runbooks oncall pager
        observability telemetry tracing metrics alerting
        whitelist allowlist blocklist denylist blacklist ratelimit throttling throttled backoff retries retry
        encrypt encrypted encryption decrypt decryption hashing hashed salted plaintext ciphertext
        authenticate authentication authorize authorization credentials token tokens keystore
        sandbox sandboxed staging prod preprod canary rollforward featureflag
        frontend backend middleware
        changelist diff diffs patch patches cherrypick stash squash squashed rebased rebasing
        submodule submodules worktree upstreamed
        codegen boilerplate scaffolding scaffold refactors deprecate deprecated deprecation
        versioning semver backport backported changelogs
        subnet subnets firewall ingress egress hostname hostnames nameserver
        dataframe dataframes ndarray tensor tensors embedding embeddings tokenization
        hyperparameter hyperparameters overfitting underfitting inference finetune finetuning
        lookup lookups enqueue dequeue timestamped
    """,
    SOMETIMES: """
        TOML INI JSONL Parquet Avro Protobuf protobufs Thrift WebSocket WebSockets WebAssembly Wasm
        SMTP IMAP FTP SFTP ICMP BGP MQTT AMQP HMAC AES RSA ECDSA PKI CIDR
        mTLS OIDC SCIM RBAC ABAC
        Istio Envoy Consul Vault Nomad Packer Vagrant Pulumi ArgoCD Flux Kustomize Minikube Rancher OpenShift
        Podman containerd etcd CoreDNS Linkerd Traefik HAProxy Varnish Memcached
        ClickHouse CockroachDB InfluxDB TimescaleDB Supabase Firebase Firestore Pinecone
        Kinesis Pulsar NATS Celery Sidekiq
        CircleCI TeamCity Bazel Buck CMake Ninja Homebrew Chocolatey
        Sentry PagerDuty Opsgenie NewRelic Honeycomb Jaeger Zipkin OpenTelemetry
        Okta Keycloak
        Kotlin Scala Clojure Haskell Erlang Elixir Lua Perl Bash Zsh PowerShell Groovy Dart Flutter
        SwiftUI UIKit AppKit Combine CoreData Jetpack
        Nuxt Remix Gatsby Astro Redux MobX Zustand RxJS
        LangChain OpenAI HuggingFace Ollama llama
        xcodebuild xcodegen SwiftLint SwiftPM CocoaPods Carthage pnpm esbuild tsconfig Rollup Turborepo
        GGUF llamacpp LoRA quantized quantization tokenizers safetensors checkpointed
        Pydantic SQLAlchemy Alembic Poetry virtualenv conda linters formatter formatters
        Tauri Electron SolidJS Storybook Zod tRPC Prisma Drizzle
        preflight preload prefetching rerender rerenders memoizing
        memoize memoization memoized debounce debounced throttle hydrate hydration rehydrate
        idempotently atomically transactional isolation serializable linearizable quorum
        consensus leaderless gossip sharded resharding rebalancing rebalance compaction
        tombstone tombstones checkpointing checkpoint checkpoints snapshotting watermark watermarks
        backpressure fanout fanin dedup denormalization
        monad monads functor functors currying curried reducer reducers thunk thunks
        vtable trampoline intrinsics prefetch vectorized vectorization
        segfault segfaults stacktraces coredump heapdump
        endianness bitfield nibble opcode opcodes mnemonic
        lexer lexers tokenizers parsers linker linkers disassembler decompiler
        refcount refcounting finalizer finalizers destructor destructors constructor constructors
        subclass subclasses superclass metaclass mixin mixins decorator decorators annotation annotations
        overload overloads overloading overriding override overrides
        enumerate enumeration deserialization serialization marshaling unmarshal
        cronjob cronjobs daemonset statefulset configmap namespaces kubeconfig
        hypervisor virtualization virtualized baremetal colocation
        bikeshedding dogfooding greenfield brownfield
        grooming backlog sprint sprints standup standups retro retros kanban scrum roadmap roadmaps
        stakeholder stakeholders deliverable deliverables milestone milestones blocker blockers
        triage triaged repro reproducible reproducibility
        screenshot screenshots tooltip tooltips dropdown dropdowns checkbox checkboxes textbox modal modals
        navbar sidebar breadcrumb breadcrumbs pagination paginated carousel
        viewport breakpoint breakpoints responsive flexbox gridlines
        favicon sitemap robots canonical redirect redirects
        localization internationalization locale locales
        accessibility focusable keybinding keybindings hotkey hotkeys shortcut shortcuts
    """,
}


# Names the dictionary lists in lowercase that are still written with a capital.
ALWAYS_CAPITALIZED = {
    "linux", "javascript", "typescript", "android", "python", "java", "docker", "kafka", "jenkins", "cassandra",
    "django", "apache", "kotlin", "perl", "haskell", "erlang", "html", "css", "sql", "php", "xml", "pdf",
}
# Four-letter terms the spelling dictionary takes: typed all day, and not a likely slip for another word.
SHORT_SPELLING_TERMS = {"json", "yaml", "html", "http", "repo", "enum", "sudo"}
SPELLING_MINIMUM_LENGTH = 5


def main():
    dictionary_path, words_path, spelling_path = sys.argv[1:4]
    with open(dictionary_path, encoding="utf-8") as file:
        dictionary = {line.split()[0] for line in file if line.strip()}
    seen = {}
    for count, block in TERMS.items():
        for term in block.split():
            key = term.lower()
            assert key.isalpha() and key.isascii(), term
            if key not in seen:
                seen[key] = (count, term)
    ordered = sorted(seen.items(), key=lambda item: (-item[1][0], item[0]))
    header = "# Written by Tools/prediction/build_technical_words.py; edit that file, not this one."

    words = ["# Software-engineering vocabulary for the word strip: word, count, usual capitals.", header]
    for key, (count, term) in ordered:
        keeps_capitals = term != key and (key not in dictionary or key in ALWAYS_CAPITALIZED)
        words.append(f"{key} {count}" + (f" {term}" if keeps_capitals else ""))
    with open(words_path, "w", encoding="utf-8") as output:
        output.write("\n".join(words) + "\n")

    spelling = ["# Software-engineering terms the spelling dictionary lacks: word, count.", header]
    for key, (count, _) in ordered:
        if key not in dictionary and (len(key) >= SPELLING_MINIMUM_LENGTH or key in SHORT_SPELLING_TERMS):
            spelling.append(f"{key} {count}")
    with open(spelling_path, "w", encoding="utf-8") as output:
        output.write("\n".join(spelling) + "\n")

    cased = sum(1 for line in words[2:] if len(line.split()) == 3)
    print(f"{len(seen)} words for the strip ({cased} with capitals), {len(spelling) - 2} for the spelling dictionary")


if __name__ == "__main__":
    main()
