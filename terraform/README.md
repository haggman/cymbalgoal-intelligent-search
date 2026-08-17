# Terraform — what built your lab cluster

You never ran this. It ran when you clicked **Start Lab**, and by the time your notebook
connected, the AlloyDB cluster existed and was waiting.

It's here because "pre-built" is doing a lot of work in that sentence, and the parts it's
hiding are the parts worth stealing for your own systems.

## What it actually provisions

The **cluster and primary instance only**—about **9 minutes**, measured in a clean project.
Nothing else. No database, no schema, no data, no indexes.

That's deliberate, and it's the first thing worth knowing:

**Terraform cannot run SQL, and there is no `google_alloydb_database` resource.** There is no
Terraform noun for "a database inside an AlloyDB cluster." Earlier versions of this config
bridged the gap with a small VM that existed only to be inside the VPC and run `psql`. The
AlloyDB Python Connector removed the need entirely—it reaches the cluster from anywhere with
IAM auth—so the VM, the NAT, the firewall rules, and the subnet all went with it. Roughly half
the config disappeared.

**And a database created by provisioning would be owned by `postgres`.** `alloydbsuperuser` is
not a real PostgreSQL superuser, so you would not be able to drop or fully manage a database
you supposedly own. In a notebook-driven lab, the student has to create it. That's why Task 1
is real work rather than a tour.

## The four things worth your attention

**1. Indexes are built after the load, never before.**

The schema file that creates the tables would happily create the vector indexes too. Run it
straight through and you build an index on an empty table—then every row you load has to be
inserted into that index one at a time. Worse, ScaNN simply refuses: `FAILED_PRECONDITION:
Cannot create ScaNN index with empty table`. Load first, index second, with
`maintenance_work_mem` raised for the build. Same rule for any bulk load into any indexed
table you will ever own.

**2. One unverified flag name kills the entire instance.**

`database_flags` is validated as a set. A single unknown name and AlloyDB rejects the whole
instance create—no warning, no partial apply. At Start Lab that means every student in the
room gets a cluster with no instance. Every name in `main.tf` was verified against
`GET .../supportedDatabaseFlags` before it was written. Also note `password.enforce_complexity`
is *mandatory* once public IP is enabled.

And `database_flags` are **per-instance, not per-cluster**. Add a read pool and you must repeat
every flag on it, or the pool quietly behaves differently from the primary and you debug that
at 2am.

**3. The service-agent IAM binding is load-bearing, and it has an ordering trap.**

Without `roles/aiplatform.user` on the AlloyDB service agent, every `ai.embedding()` call
fails—so every vector search in the lab fails. The cluster builds fine, the load succeeds, and
the whole thing dies at the first semantic query. The agent does not exist until the cluster
does, so the binding needs an explicit `depends_on`.

**4. Two bugs that only appear on the *second* apply.**

`google_alloydb_user.database_roles` declares the complete role set, and AlloyDB grants
`alloydbiamuser` automatically. List only `alloydbsuperuser` and the second apply reads it as
a revoke: `Error 400: cannot revoke IAM roles`. Then—`database_roles` is a **list, not a set**,
and the API returns the roles sorted, so declaring them in any other order is a permanent diff
forever. Both live in one four-line resource. Both are invisible to a first apply.

The general lesson is the one this whole config was built on: **apply twice**. `terraform plan
-detailed-exitcode` should exit 0 the second time. Anything that only breaks on re-apply is
exactly the thing that breaks in production.

## What it deliberately does NOT do

- **No BM25 index.** Building it is Task 3—the lab *is* watching keyword search fail and then
  fixing it.
- **No read pool.** The shape was inherited from an earlier lab without inheriting a reason. No
  task in any of the three CymbalGoal labs needs one, and it costs provisioning time on every
  student's cluster.
- **No authorized networks.** None at all. IAM gates access and the Python Connector carries
  mTLS, so the public IP is not an open door. Measured: connects in 0.5 s with the allowlist
  empty.

## Rebuilding in your own project

Terraform 1.12+, google provider 7.x, and a project with billing plus the AlloyDB and Vertex AI
APIs. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill it in.

Region must be `us-central1` or `us-east1`: `ai.embedding()` calls Vertex from the cluster's own
region, and `gemini-embedding-001` is not served everywhere. There's a `validation` block that
will stop you rather than let you find out at query time.

⚠️ **`username` is the local part only**, with no `@domain`—that's what the lab platform hands
in, and `main.tf` appends the domain itself. Applying in a personal project? Set
`student_email_domain` to your own.

The one thing you cannot copy is the data: the staged corpus lives in a course-owned bucket.
`../notebooks/` shows how it was built, from public CC0 data.
