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

`technical_spelling_en.txt` is for the spelling dictionary: the terms the dictionary lacks. A term
there is no longer flagged or "fixed" (`tokio` was typed as `tokyo`, `saml` as `same`, `nuxt` as
`next`). It is stricter than the strip's list because the risk is different, and has three rules:

- A term that is itself a likely slip for a common word stays out, or the slip would look right:
  `aws` is `was` with two keys swapped, `util` is `until` with a letter dropped, `iam` is `I am` run
  together, `sso` is `so` with a key struck twice, `paas` is `pass` with the key beside it
  (`slip_for_a_common_word`). `systemd` is `systems` by the same test. `cors` is `course` spelled by
  sound, which no rule about keys can see, so it is named (`KEPT_OUT_BY_NAME`). The strip still
  offers all of these.
- The count decides how hard a term pulls slips toward itself. The engine treats its 30,000 most
  common words (a count of about half a million and up) as likely fixes. DAILY and WEEKLY terms
  are above that: `frontned` becomes frontend and `josn` json. The price is that a slip lying
  between such a term and a common word gets the bar and not an automatic fix (`lignting`:
  lighting or linting). SOMETIMES terms are below it: accepted as typed, offered for their own slips
  where no common word is as close, and never in the way of an ordinary fix. So a term one key from
  a far more common word that is not typed every week (`semver`, one key from `server`) belongs in
  SOMETIMES, whatever its place would be otherwise.
- A term of three or four letters is only ever accepted as typed (`QUIET`), apart from the seven
  typed all day (`SHORT_SPELLING_TERMS`): three letters are one slip from too many ordinary words
  for the term to be a fix (`cdn` from `can` and `con`, `jwt` from `jet`). Two-letter terms stay
  out.

Raising the count of a word the dictionary already has would change which ordinary word a slip is
fixed to, so those are never written here.

Only single words made of letters go in: the word under the caret is found by its letters, so
`k8s`, `oauth2` and `read-only` could never be matched.

Usage:
  python3 -I Tools/prediction/build_technical_words.py Cotabby/Resources/frequency_dictionary_en_82_765.txt \
      Cotabby/Resources/technical_words_en.txt Cotabby/Resources/technical_spelling_en.txt
"""
import string
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
        nginx Apache Tomcat RabbitMQ MongoDB DynamoDB Cassandra SQLite Snowflake Databricks BigQuery Redshift
        Airflow Spark Hadoop Flink Hive Presto Trino dbt Tableau Looker
        Azure GCP Heroku Vercel Netlify Cloudflare Lambda Fargate
        Jira Confluence Slack Figma Postman Swagger OpenAPI Bitbucket Xcode Gradle Maven webpack Vite Babel ESLint
        Prettier pytest JUnit Jest Cypress Selenium Playwright
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
        versioning backport backported changelogs
        subnet subnets firewall ingress egress hostname hostnames nameserver
        dataframe dataframes ndarray tensor tensors embedding embeddings tokenization
        hyperparameter hyperparameters overfitting underfitting inference finetune finetuning
        lookup lookups enqueue dequeue timestamped
        TTL TTLs UID UIDs UUID UUIDs PID PIDs LLM LLMs RFC RFCs SDKs KPIs OKR OKRs ACL ACLs MVP POC EOF OOM
        PII MFA OTP UTF ASCII Unicode
    """,
    SOMETIMES: """
        TOML INI JSONL Parquet Avro Protobuf protobufs Thrift WebSocket WebSockets WebAssembly Wasm
        SMTP IMAP FTP SFTP ICMP BGP MQTT AMQP HMAC AES RSA ECDSA PKI CIDR
        mTLS OIDC SCIM RBAC ABAC
        Istio Envoy Consul Vault Nomad Packer Vagrant Pulumi ArgoCD Flux Kustomize minikube Rancher OpenShift
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
        semver
        Tokio reqwest thiserror Serde rustc rustfmt Clippy
        asyncio Uvicorn Gunicorn mypy Pylint SciPy sklearn Matplotlib Polars PySpark venv pyenv pyproject
        IPython HTTPX ONNX CUDA MLflow kwargs argparse stdlib
        Deno Vitest Axios JSX TSX npx nvm htmx SvelteKit NestJS
        TestFlight adb APK XCTest
        tfstate CloudFormation CloudWatch CloudFront SageMaker gcloud Dataflow Tailscale WireGuard OpenSSL OpenSSH
        systemd systemctl cgroup cgroups wget rsync tmux Neovim nvim Emacs zshrc bashrc dotenv xargs ripgrep
        GDB ASan LLVM GCC ECR ELB EBS
        psql pgvector DuckDB MariaDB OLAP CDC UDF UDFs CTE CTEs DDL DML
        DHCP SSE SSR CSR SEO JWTs CVE CVEs GDPR
        QPS SIGTERM SIGKILL FIXME WIP LGTM todo todos
        CODEOWNERS Dependabot
        builtins printf nullptr instanceof typeof readonly const bool uint func impl argv argc falsy truthy
        polyfill polyfills transpiled sourcemap sourcemaps linted typings stringify serializer serializers
        validator validators preprocess preprocessing preprocessor initializer accessor deprioritize deprioritized
        runtimes subprocess subprocesses codepath hardcode hardcoded hardcoding untyped mutexes
        autoscaler CRD CRDs dockerized entrypoint entrypoints rollouts teardown hotfixes bugfixes
        finetuned pretrained pretraining logits softmax backpropagation dataloader dataloaders multimodal
        rerank reranking GPT
        ngrok Twilio OpenSearch
    """,
}


# Names the dictionary lists in lowercase that are still written with a capital.
ALWAYS_CAPITALIZED = {
    "linux", "javascript", "typescript", "android", "python", "java", "docker", "kafka", "jenkins", "cassandra",
    "django", "apache", "kotlin", "perl", "haskell", "erlang", "html", "css", "sql", "php", "xml", "pdf",
    "emacs", "unicode", "rfcs",
}
# Four-letter terms the spelling dictionary takes at their full count, so that slips are fixed
# toward them: typed all day, and not a likely slip for another word.
SHORT_SPELLING_TERMS = {"json", "yaml", "html", "http", "repo", "enum", "sudo"}
SPELLING_MINIMUM_LENGTH = 5
# Every other term of three or four letters is written with this count: below the engine's
# common-word floor, so it is accepted as typed and is never what a slip is fixed to.
SHORT_MINIMUM_LENGTH = 3
QUIET = SOMETIMES
# A word this common is typed so often that a term spelling one of its slips is more likely the slip.
# The dictionary was counted on the web, so below this it is full of labels nobody types in a
# sentence (`del`, `pic`, `avg`, `rom`), which would keep `ddl`, `poc`, `svg` and `orm` out.
COMMON_WORD_COUNT = 50_000_000
# Kept out by name, where `slip_for_a_common_word` cannot see the slip: `cors` is `course` spelled
# by sound (`of cors` is fixed to `of course`), and `slo` is `slow` cut short, a word just under the
# count above. `env` and `api` were kept out when the list was first made; the system's checker
# accepts both as typed, so nothing is lost by leaving that as it was.
KEPT_OUT_BY_NAME = {"cors": "course", "slo": "slow", "env": "an earlier choice", "api": "an earlier choice"}

KEY_ROWS = ("qwertyuiop", "asdfghjkl", "zxcvbnm")


def neighbouring_keys():
    """Each letter's neighbours on a QWERTY keyboard: beside it, and the two it sits between above and below."""
    neighbours = {letter: set() for letter in string.ascii_lowercase}
    for row, keys in enumerate(KEY_ROWS):
        for column, key in enumerate(keys):
            beside = [keys[index] for index in (column - 1, column + 1) if 0 <= index < len(keys)]
            below = KEY_ROWS[row + 1] if row + 1 < len(KEY_ROWS) else ""
            # Each row is shifted half a key to the right of the one above: `w` sits over `a` and `s`.
            under = [below[index] for index in (column - 1, column) if 0 <= index < len(below)]
            for other in beside + under:
                neighbours[key].add(other)
                neighbours[other].add(key)
    return neighbours


NEIGHBOURS = neighbouring_keys()


def slip_for_a_common_word(term, counts):
    """The common word (or pair of words) that `term` is one ordinary slip away from, or None.

    The slips are the ones a hand makes: two keys in the wrong order, a key struck twice, the key
    beside the right one, a letter left out, and, for a short term, two words run together (a long
    one made of two words is the term itself: `backend`, `namespace`). A stray extra letter is not
    one of them (`wasm` is not `was`), nor is a wrong letter from across the keyboard.
    """
    def common(word):
        return counts.get(word, 0) >= COMMON_WORD_COUNT

    if term in KEPT_OUT_BY_NAME:
        return KEPT_OUT_BY_NAME[term]
    slips = []
    for index, letter in enumerate(term):
        rest = term[index + 1:]
        if rest:
            slips.append(term[:index] + rest[0] + letter + rest[1:])
            if rest[0] == letter:
                slips.append(term[:index] + rest)
        slips += [term[:index] + key + rest for key in sorted(NEIGHBOURS[letter])]
    for index in range(len(term) + 1):
        slips += [term[:index] + letter + term[index:] for letter in string.ascii_lowercase]
    for word in slips:
        if common(word):
            return word
    if len(term) >= SPELLING_MINIMUM_LENGTH:
        return None
    for index in range(1, len(term)):
        halves = (term[:index], term[index:])
        # `a` and `I` are the only one-letter words; the dictionary also counts stray letters.
        if all(common(half) and (len(half) > 1 or half in "ai") for half in halves):
            return " ".join(halves)
    return None


def main():
    dictionary_path, words_path, spelling_path = sys.argv[1:4]
    with open(dictionary_path, encoding="utf-8") as file:
        dictionary = {fields[0]: int(fields[1]) for fields in map(str.split, file) if len(fields) == 2}
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
    slips = []
    for key, (count, _) in ordered:
        if key in dictionary or len(key) < SHORT_MINIMUM_LENGTH:
            continue
        if key in SHORT_SPELLING_TERMS:
            spelling.append(f"{key} {count}")
            continue
        intended = slip_for_a_common_word(key, dictionary)
        if intended:
            slips.append(f"{key} ({intended})")
        else:
            spelling.append(f"{key} {count if len(key) >= SPELLING_MINIMUM_LENGTH else min(count, QUIET)}")
    with open(spelling_path, "w", encoding="utf-8") as output:
        output.write("\n".join(spelling) + "\n")

    cased = sum(1 for line in words[2:] if len(line.split()) == 3)
    print(f"{len(seen)} words for the strip ({cased} with capitals), {len(spelling) - 2} for the spelling dictionary")
    print(f"{len(slips)} kept out of the spelling dictionary as likely slips: {', '.join(sorted(slips))}")


if __name__ == "__main__":
    main()
