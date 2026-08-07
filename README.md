# HMCTS Dev Test Backend

Spring Boot service for the HMCTS case management system, wired to PostgreSQL and shipped as a container. This repository holds the application, its delivery pipeline and the Terraform that defines its production infrastructure on Azure.

| Area | Where |
| --- | --- |
| Application config | `src/main/resources/application.yaml` |
| Container image | `Dockerfile`, `.dockerignore` |
| Local stack | `docker-compose.yml`, `.env.example` |
| Pipeline | `.github/workflows/`, `.github/actions/terraform`, `.trivyignore.yaml` |
| Infrastructure | `infrastructure/terraform/` |

Docker is the only requirement to run the service. JDK 21 and Terraform 1.15 are needed only to run the build or the infrastructure checks directly.

## Contents

- [Running locally with Docker Compose](#running-locally-with-docker-compose)
  - [Application changes](#application-changes)
- [CI/CD](#cicd)
  - [Feature branch vs master](#feature-branch-vs-master)
  - [Image tagging](#image-tagging)
  - [Gates](#gates)
  - [Accepted findings](#accepted-findings)
  - [Repository secrets](#repository-secrets)
- [Infrastructure](#infrastructure)
  - [Why Container Apps](#why-container-apps)
  - [Naming and tagging](#naming-and-tagging)
  - [Environments](#environments)
  - [How credentials reach the application](#how-credentials-reach-the-application)
  - [Why no variable is marked `sensitive`](#why-no-variable-is-marked-sensitive)
  - [Checking the configuration](#checking-the-configuration)
  - [First deployment to a new subscription](#first-deployment-to-a-new-subscription)
  - [Running a deployment](#running-a-deployment)
  - [Remote state](#remote-state)
- [Assumptions and trade-offs](#assumptions-and-trade-offs)

---

## Running locally with Docker Compose

```bash
cp .env.example .env
docker compose up --build
```

Once `docker compose ps` shows both services healthy:

```bash
curl http://localhost:4000/                  # welcome message
curl http://localhost:4000/get-example-case  # sample case JSON
curl http://localhost:4000/health            # includes the database check
```

`/health` reports a `db` component only when the datasource is genuinely connected, so a green response confirms the wiring:

```json
{
  "status": "UP",
  "components": {
    "db": { "status": "UP", "details": { "database": "PostgreSQL", "validationQuery": "isValid()" } }
  }
}
```

Stop the database and call `/health/readiness` to see the failure mode: DOWN with a 503, which is what removes a replica from the load balancer in Azure.

Tear down with `docker compose down`, or `-v` to drop the database volume.

`.env` is git-ignored; `.env.example` is the committed template. No password appears in the repository, the image or `docker-compose.yml`.

### Application changes

The datasource is driven by `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER_NAME`, `DB_PASSWORD` and `DB_OPTIONS`. Health is on the actuator exposure list and probes are enabled, so `/health/liveness` and `/health/readiness` exist separately. `build.gradle` adds `spring-boot-starter-jdbc` and the PostgreSQL driver.

The readiness group is `readinessState,db` rather than just `db`: declaring a group replaces the default, and dropping `readinessState` would leave readiness reporting UP throughout graceful shutdown.

The image is multi-stage, runs as a non-root user, and sizes the heap from the container limit.

---

## CI/CD

`ci.yml` holds the triggers and job graph; each stage is a reusable workflow.

| Job | Defined in | What it does |
| --- | --- | --- |
| **Build and test** | `_build-test.yml` | Checkstyle, then `./gradlew build` for unit and integration tests. Reports uploaded as artefacts. |
| **Terraform checks** | `_terraform-checks.yml` | `fmt -check -recursive`, `init -backend=false`, `validate`, plus a Trivy misconfiguration scan. |
| **Image build and scan** | `_image.yml` | Builds the image and scans it with Trivy. Publishes on master. |
| **CI gate** | `ci.yml` | Single aggregate check for branch protection. |

`deploy.yml` takes an environment and an image tag. `destroy.yml` tears an environment down; `prd` is not one of its options.

`.github/actions/terraform` is a composite action shared by the checks job and both deploy jobs. It installs the pinned version and runs `init`, with or without the remote backend.

### Feature branch vs master

CI runs on every push to every branch, and every branch runs the same checks. What changes is what the run is allowed to produce.

| | Feature branch | master and `v*.*.*` tags |
| --- | --- | --- |
| Build, test, scan | yes | yes |
| Azure login | never | OIDC federated login |
| Image pushed to the registry | no | yes |
| Tags applied | `sha-<sha>`, branch name | also `master`, `latest`, semver |
| Gradle cache | read-only | writes |
| Superseded runs | cancelled | allowed to finish |

Publishing is decided by the ref, not by the event, and only once the registry and the identity that reaches it are both configured:

```yaml
PUBLISH: ${{ (github.ref == 'refs/heads/master' || startsWith(github.ref, 'refs/tags/v'))
             && secrets.ACR_LOGIN_SERVER != '' && secrets.AZURE_CLIENT_ID != '' }}
```

Half a configuration skips with a notice naming what is missing, rather than failing the build. A fork with no Azure account behind it still gets a green pipeline.

A feature branch therefore gets full feedback, including the container scan, without any cloud credential being available to unreviewed code. The image is built and loaded locally so the scan runs against the exact artefact master would later push. Deployment is a separate workflow, so the permissions that can change production are not attached to every CI run.

### Image tagging

| Tag | When | Purpose |
| --- | --- | --- |
| `sha-<short sha>` | Every build | Immutable, one commit, one artefact. The only tag deployments use. |
| `master` | Default branch | Moving pointer at the tip of master. |
| `1.4.2`, `1.4`, `1` | `v*.*.*` git tag | Marked release with the usual aliases. |
| `latest` | Default branch | Convenience for manual pulls. |

A rollback has to name the exact artefact that was running before, which a moving tag cannot do. `image_tag` has no default in Terraform, so a deployment always names what it is shipping.

### Gates

**Blocking a merge.** The `ci-gate` job aggregates the result of every other job and fails if any did not succeed, so branch protection needs one required check rather than a list that drifts as jobs are added. It fails on any of:

| Failure | From |
| --- | --- |
| Checkstyle violation | `_build-test.yml` |
| Failing unit or integration test | `_build-test.yml` |
| Unformatted HCL, or Terraform that does not validate | `_terraform-checks.yml` |
| CRITICAL infrastructure misconfiguration | `_terraform-checks.yml` |
| CRITICAL CVE with a fix available | `_image.yml` |
| Image does not build | `_image.yml` |

Branch protection on `master` should require the **CI gate** check, a pull request with one approving review, branches up to date before merging, and no force pushes.

One severity policy covers both scanners: CRITICAL blocks, HIGH warns with a count and a pointer to the Security tab, MEDIUM and above is uploaded for triage. A hard block on HIGH means a base image CVE with no available fix stops all delivery, including the security fixes that need to ship; `ignore-unfixed` is on for the same reason. Every SARIF step sets `limit-severities-for-sarif`, which defaults to false and otherwise uploads every severity regardless of the filter.

**Blocking a release.** A deployment can only name an image tag that exists in the registry, and only master and version tags push there, so nothing that failed CI is deployable. `deploy.yml` plans before it applies, the apply job sits behind the environment's required reviewers, and the smoke test against `/health/readiness` fails the run if the new revision starts but cannot reach the database.

### Accepted findings

`.trivyignore.yaml` holds the exceptions. Each one carries the reason and a date it is revisited; when that date passes the entry stops suppressing and the check fails, so an exception cannot quietly become permanent.

| Finding | Why it is accepted |
| --- | --- |
| `AVD-AZU-0013` Key Vault network ACL | Container Apps is not a Key Vault trusted service and has no stable outbound address while the environment has no VNet integration, so a deny-by-default ACL has nothing to allowlist. RBAC and a managed identity carry the control. |
| `AVD-AZU-0022` public database access | Same root cause. The server accepts Azure services only and requires TLS. |
| `AVD-AZU-0017` secret expiry date | An expiry on a credential with no automated rotation is a scheduled outage. |
| `AVD-AZU-0021` connection throttling, `AVD-AZU-0026` minimum TLS | Both read attributes of the retired Single Server. Throttling is set through `connection_throttle.enable`, and Flexible Server enforces TLS 1.2 by default. |

The first two close together by moving to a workload profile environment with private endpoints, which is listed under *With more time*.

### Repository secrets

| Secret | Used for |
| --- | --- |
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | OIDC federated login |
| `ACR_NAME`, `ACR_LOGIN_SERVER` | Registry push target |
| `TF_STATE_RESOURCE_GROUP`, `TF_STATE_STORAGE_ACCOUNT` | Remote state backend |

None of these is needed for CI to pass. Build, test, Checkstyle, the Terraform checks and the container scan all run without an Azure account; the secrets only gate publishing and deployment.

---

## Infrastructure

A single root module, one file per resource type.

```
main.tf           terraform block, commented backend, provider, resource group
locals.tf         naming patterns and the container configuration maps
variables.tf      every input, typed and described
database.tf       generated password, PostgreSQL server, database, parameters, firewall
keyvault.tf       vault, credential secrets, RBAC grants
compute.tf        managed identity, Container Apps environment, the application
registry.tf       lookup of the shared registry and the AcrPull grant
log_analytics.tf  workspace backing Container Apps logs
outputs.tf        grouped outputs for operators and the deploy job
envs/*.tfvars     per-environment values, selected with -var-file
```

### Why Container Apps

Over App Service for Containers, for a stateless HTTP API: request-based autoscaling with a low floor so idle cost tracks usage; revisions and traffic splitting give blue/green and canary with no extra infrastructure; Key Vault secret references and managed-identity registry pulls are first class, so no credential sits in app configuration.

### Naming and tagging

Resources are named `<organization>-<abbreviation>-<service>-<environment>-<location>`:

| Resource | Name |
| --- | --- |
| Resource group | `hmcts-rg-cms-prd-uks` |
| PostgreSQL server | `hmcts-psql-cms-prd-uks` |
| Container App | `hmcts-ca-cms-prd-uks` |
| Key Vault | `hmcts-kv-cms-prd-uks` |

Names use `service.formattedName`, which keeps every name inside its Azure limit; the full `service.name` names the container inside the app. `var.tags` is applied unchanged to every resource.

The container registry is the exception. It is shared across services and environments, so it is read with a data source rather than created here, and it carries no environment in its name.

### Environments

One configuration, one state file per environment, selected by `-var-file=envs/<env>.tfvars`. `environment` feeds the resource names and the state key, so `dev` and `prd` never collide.

| | dev | prd |
| --- | --- | --- |
| PostgreSQL | `B_Standard_B1ms`, 32 GB, 7-day backups | `GP_Standard_D2s_v3`, 64 GB, 35-day geo-redundant |
| High availability | off | zone-redundant standby |
| Container | 0.5 vCPU, 1 Gi, 0 to 2 replicas | 1 vCPU, 2 Gi, 2 to 10 replicas |
| Log retention | 30 days | 90 days |
| Key Vault soft delete | 7 days | 90 days |
| Delete protection | off | on |

Everything an environment sets is a variable; `locals.tf` holds only what is derived from them, such as the resource names and the container configuration maps. Adding an environment is a new tfvars file, not a code change.

`delete_protection_enabled` decides whether an environment can be torn down. It drives Key Vault purge protection and whether the provider purges a soft-deleted vault. With it off, `terraform destroy` removes everything and frees the vault name immediately; with it on, a destroyed vault stays recoverable and its name is reserved for the retention period.

Production is protected by process rather than by a lifecycle rule: `destroy.yml` has no `prd` option, and the apply job waits on the environment's required reviewers. A `prevent_destroy` rule cannot vary by environment, because Terraform requires it to be a literal.

Only the Azure infrastructure is environment-aware. Docker Compose is a single local stack driven by `.env`, and the application itself carries no per-environment configuration.

### How credentials reach the application

Terraform generates the database password with `random_password` and writes it to Key Vault. The same value sets `administrator_password` on the server in that apply, because Terraform cannot read it back out of the vault at the moment it creates the server.

The Container App declares its secrets as Key Vault references rather than values, resolved at run time by a user-assigned managed identity holding `Key Vault Secrets User`. `DB_USER_NAME` and `DB_PASSWORD` arrive as secret-backed environment variables; `DB_HOST`, `DB_PORT`, `DB_NAME` and `DB_OPTIONS` are plain values.

The identity is user-assigned because a system-assigned one does not exist until the Container App is created, so its RBAC grants could not be in place before the first revision pulls an image and reads its secrets.

### Why no variable is marked `sensitive`

This is a deliberate choice, not an omission. Nothing sensitive is an *input* to this configuration. Terraform generates the database password with `random_password`, writes it to Key Vault, and the Container App resolves it at run time through a managed identity. The value never passes through a variable, a tfvars file or a `-var` argument, so there is no variable to mark.

The alternative is to create the credential outside Terraform and pass it in:

```hcl
variable "postgres_admin_password" {
  description = "PostgreSQL administrator password, supplied by the pipeline."
  type        = string
  sensitive   = true
}
```

set from a pipeline secret. That is the right shape when the credential is shared with something Terraform does not manage, or when rotation is owned elsewhere. Here it would only create another route for a secret to reach the repository, which is the thing the requirement exists to prevent.

Worth being precise about what the flag does either way: `sensitive = true` redacts a value from CLI output and the plan. It does not redact it from state. State holds the generated password in plain text regardless, which is why the state account is treated as a secret store and why the plan is never uploaded as an artefact.

### Checking the configuration

```bash
cd infrastructure/terraform
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
```

None of these needs an Azure account, which is why they run in CI on every push. `plan` authenticates against Azure, so it lives in the deploy workflow.

### First deployment to a new subscription

Shared infrastructure cannot be created by the service that consumes it, so it is created once, before the first apply.

1. Create the state storage account and container, and the shared container registry.
2. Create an Entra ID app registration with federated credentials for this repository. Grant it Contributor and Role Based Access Administrator on the subscription and on the registry's resource group, and Storage Blob Data Contributor on the state account.
3. Uncomment the backend block in `main.tf`, set the repository secrets, and point `registry_name` and `registry_resource_group_name` at the registry.
4. Merge to `master` so CI pushes an image, then run Deploy with that `sha-` tag.

Because the registry is read with a data source, `plan` fails with a not-found error until step 1 is done, and the identity running the plan needs read access to it. `terraform validate` does not read data sources, so the checks in CI are unaffected either way.

### Running a deployment

1. Merge to `master`. CI builds, scans and pushes the image, and prints the `sha-` tag in the job summary.
2. **Actions → Deploy → Run workflow.** Choose the environment and paste that tag.
3. `resolve` settles the tag and environment, `plan` prints the diff to the job summary, and `apply` waits for the environment's required reviewers before applying and smoke testing `/health/readiness`.

The plan is not uploaded as an artefact, because a saved plan holds every planned attribute in the clear, including the generated password.

To tear down a lower environment, **Actions → Destroy**, choose it and type the name to confirm.

The same thing locally, with Azure credentials and the backend block uncommented:

```bash
cd infrastructure/terraform
terraform init
terraform plan  -var-file=envs/dev.tfvars -var="image_tag=sha-1a2b3c4"
terraform apply -var-file=envs/dev.tfvars -var="image_tag=sha-1a2b3c4"
terraform destroy -var-file=envs/dev.tfvars -var="image_tag=unused"
```

### Remote state

State lives in an Azure Storage account. The block is in `main.tf`, commented out so `terraform validate` runs without credentials:

```hcl
backend "azurerm" {
  resource_group_name  = "hmcts-rg-terraform-state-prd-uks"
  storage_account_name = "hmctssttfstateprduks"
  container_name       = "tfstate"
  key                  = "cms/prd.tfstate"
  use_azuread_auth     = true
  use_oidc             = true
}
```

`use_azuread_auth` and `use_oidc` make the backend authenticate as the pipeline's federated identity rather than with a storage account key. The storage account is created once, outside this configuration, and should have blob versioning, soft delete and a resource lock. State is sensitive because it holds the generated password in plain text.

In the pipeline the composite action passes these values as `-backend-config` flags, so one configuration serves several environments by varying the state `key`.

---

## Assumptions and trade-offs

**Assumptions**

- The application is stateless. No schema migration tool is included.
- One environment shape parameterised by `environment`, with sizing and delete protection set per environment in `envs/`.
- `master` is the default branch.
- The state storage account, the shared container registry and the Entra ID app registration for OIDC are bootstrapped separately.

**Trade-offs**

- **Scope.** The configuration covers the resource group, database, compute and Key Vault, plus the workspace those depend on. Private networking, diagnostic settings and alerting are the next additions for a live service.
- **The registry is read, not created.** It has a different lifecycle from the service: shared across environments, and it must outlive any environment that gets torn down. Owning it here would give each environment its own registry, which quietly breaks build once and deploy everywhere, because the artefact tested in dev would not be the artefact shipped to prd. The cost is a bootstrap step and a data source that fails the plan if the registry is missing.
- **Public endpoints on the database and vault.** A Container Apps environment without VNet integration has no stable outbound address, and Container Apps is not a Key Vault trusted service, so there is nothing specific to allowlist. RBAC, TLS enforcement and least-privilege roles carry the security in the meantime. This is the accepted finding behind `AVD-AZU-0013` and `AVD-AZU-0022`.
- **Password authentication.** Entra authentication would remove the stored credential entirely, but the datasource expects a username and password.
- **HIGH CVEs warn rather than block.** The alternative stops delivery on findings the team cannot fix.
- **Ubuntu base rather than Alpine.** Around 90 MB of image size traded for reliable multi-architecture builds.
- **Deterministic names with no random suffix.** Predictable names are worth more operationally than guaranteed uniqueness, and a collision is a clear apply-time error.

**With more time**

- Private networking: a VNet-integrated environment, PostgreSQL on private access and private endpoints for the vault.
- Diagnostic settings and alerting on database availability, replica restarts and storage headroom.
- Automated rotation of the database credential, which is what makes an expiry date on the Key Vault secret safe to set.
- Flyway or Liquibase for schema migrations, run before the new revision takes traffic.
- Front Door or Application Gateway with WAF in front of the ingress.
- Canary rollout using Container Apps traffic weights rather than the current all-at-once revision switch.
- `terraform plan` posted as a pull request comment. An HCL diff does not tell a reviewer whether a resource is being updated or replaced.
- Path filters, so an application-only change does not wait on the Terraform job and vice versa.
- The SKUs and replica counts are placeholders; real numbers would come from load testing.
