# GCP CMEK OIDC / Workload Identity (test setup)

## Table of contents

- [Scalr API vs GCP setup (read this first)](#scalr-api-vs-gcp-setup-read-this-first)
- [1 · Workload identity pool](#1--workload-identity-pool)
- [2 · OIDC provider (trust Scalr issuer)](#2--oidc-provider-trust-scalr-issuer)
- [3 · KMS key ring + crypto key (`global`)](#3--kms-key-ring--crypto-key-global)
- [4 · IAM: grant KMS access (pick **Option A** or **Option B**)](#4--iam-grant-kms-access-pick-option-a-or-option-b)
- [5 · Scalr API (`google-credentials-type` = `oidc`)](#5--scalr-api-google-credentials-type--oidc)
- [6 · Optional: full second stack for side-by-side A/B tests](#6--optional-full-second-stack-for-side-by-side-ab-tests)
- [Cleanup · Tear down](#cleanup--tear-down)

Scalr issues an OIDC ID token (`taco/app/encryption/service/oidc.py`: `iss`, `aud`, `sub`, `scalr_account_id`, `scalr_account_name`). GCP **Workload Identity Federation** trusts that issuer. The JWT audience Scalr uses for GCP is:

`//iam.googleapis.com/{google-workload-provider-name}`

(resource path: `projects/{PROJECT_NUMBER}/locations/global/workloadIdentityPools/{POOL}/providers/{PROVIDER}` — see `taco/app/encryption/v1/factory.py` and `taco/database/encryption.py`.)

## Scalr API vs GCP setup (read this first)

| Scalr / checklist | `google-service-account-email` in API | GCP: who holds `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key |
|-------------------|--------------------------------------|------------------------------------------------------------------------|
| **Option A** — direct WIF | Omit (null) | **`principalSet`** for your workload pool (external workload principal) |
| **Option B** — WIF + SA impersonation | Set to runtime SA email | **Google service account**; pool **`principalSet`** has `roles/iam.workloadIdentityUser` on that SA |

Use **one** row for a given test account. You can run both setups in parallel only if you use **separate** pools/keys/Scalr CMEK profiles.

---

| Variable | Meaning |
|----------|---------|
| `CMEK_GCP_PROJECT` | GCP project id (pool, provider, KMS, SA) |
| `CMEK_GCP_PROJECT_NUMBER` | Project **number** (required in WIF and `principalSet` paths) |
| `CMEK_GCP_POOL_ID` | Workload identity pool id (pick a new id if a deleted pool name still returns `ALREADY_EXISTS` for ~30 days) |
| `CMEK_GCP_PROVIDER_ID` | OIDC provider id in that pool |
| `CMEK_SCALR_HOSTNAME` | Scalr host only (same as browser URL host, no scheme) |
| `CMEK_SCALR_ISSUER` | `https://${CMEK_SCALR_HOSTNAME}` (must match provider **issuer-uri**) |
| `CMEK_GCP_SA_RUNTIME_NAME` | SA account id for **Option B** only (lowercase, digits, hyphens) |
| `CMEK_GCP_SA_RUNTIME` | Full SA email `${CMEK_GCP_SA_RUNTIME_NAME}@${CMEK_GCP_PROJECT}.iam.gserviceaccount.com` |
| `CMEK_GCP_KEY_RING` / `CMEK_GCP_KEY_ID` | KMS key ids (`global` location) |
| `CMEK_GCP_KMS_KEY_NAME` | Full crypto key resource name for Scalr |
| `CMEK_GCP_WORKLOAD_PROVIDER_NAME` | Provider resource path (no `//iam.googleapis.com/` prefix) |
| `CMEK_GCP_OIDC_AUDIENCE` | Full STS audience: `//iam.googleapis.com/${CMEK_GCP_WORKLOAD_PROVIDER_NAME}` |
| `CMEK_GCP_WIF_PRINCIPAL_SET` | IAM member for **all** identities in the pool (`…/POOL_ID/*`). OK for quick tests; avoid in production. |
| `CMEK_SCALR_ACCOUNT_NAME` | Scalr **account name** (slug) when locking KMS to one tenant, e.g. `dummy` |
| `CMEK_GCP_WIF_WORKLOAD_SUBJECT` | WIF **subject** = JWT `sub` from Scalr: `account:${CMEK_SCALR_ACCOUNT_NAME}` (see `issue_server_token` in `taco/app/encryption/service/oidc.py`) |
| `CMEK_GCP_WIF_PRINCIPAL_SINGLE` | One workload principal: `principal://iam.googleapis.com/projects/…/workloadIdentityPools/${CMEK_GCP_POOL_ID}/subject/${CMEK_GCP_WIF_WORKLOAD_SUBJECT}` |

```bash
export CMEK_GCP_PROJECT="your-project-id"
export CMEK_GCP_PROJECT_NUMBER="$(gcloud projects describe "${CMEK_GCP_PROJECT}" --format='value(projectNumber)')"
export CMEK_GCP_POOL_ID="scalr-cmek-workload-pool"
export CMEK_GCP_PROVIDER_ID="scalr-cmek-oidc"
export CMEK_SCALR_HOSTNAME="your-env.scalr.io"
export CMEK_SCALR_ISSUER="https://${CMEK_SCALR_HOSTNAME}"
export CMEK_GCP_KEY_RING="scalr-cmek-ring"
export CMEK_GCP_KEY_ID="scalr-cmek-key"
export CMEK_GCP_SA_RUNTIME_NAME="cmek-wif"
export CMEK_GCP_SA_RUNTIME="${CMEK_GCP_SA_RUNTIME_NAME}@${CMEK_GCP_PROJECT}.iam.gserviceaccount.com"
export CMEK_GCP_WORKLOAD_PROVIDER_NAME="projects/${CMEK_GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${CMEK_GCP_POOL_ID}/providers/${CMEK_GCP_PROVIDER_ID}"
export CMEK_GCP_OIDC_AUDIENCE="//iam.googleapis.com/${CMEK_GCP_WORKLOAD_PROVIDER_NAME}"
export CMEK_GCP_WIF_PRINCIPAL_SET="principalSet://iam.googleapis.com/projects/${CMEK_GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${CMEK_GCP_POOL_ID}/*"
export CMEK_SCALR_ACCOUNT_NAME="change-me"
export CMEK_GCP_WIF_WORKLOAD_SUBJECT="account:${CMEK_SCALR_ACCOUNT_NAME}"
export CMEK_GCP_WIF_PRINCIPAL_SINGLE="principal://iam.googleapis.com/projects/${CMEK_GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${CMEK_GCP_POOL_ID}/subject/${CMEK_GCP_WIF_WORKLOAD_SUBJECT}"
export CMEK_GCP_KMS_KEY_NAME="projects/${CMEK_GCP_PROJECT}/locations/global/keyRings/${CMEK_GCP_KEY_RING}/cryptoKeys/${CMEK_GCP_KEY_ID}"
```

Scalr sets JWT `aud` to `$CMEK_GCP_OIDC_AUDIENCE`. Allowed audiences on the provider must include that string.

---

## 1 · Workload identity pool

```bash
gcloud iam workload-identity-pools create "${CMEK_GCP_POOL_ID}" \
  --project="${CMEK_GCP_PROJECT}" \
  --location="global" \
  --display-name="Scalr CMEK"
```

---

## 2 · OIDC provider (trust Scalr issuer)

Map token claims into attributes (tighten IAM later with attribute conditions if needed).

```bash
gcloud iam workload-identity-pools providers create-oidc "${CMEK_GCP_PROVIDER_ID}" \
  --project="${CMEK_GCP_PROJECT}" \
  --location="global" \
  --workload-identity-pool="${CMEK_GCP_POOL_ID}" \
  --display-name="Scalr OIDC" \
  --issuer-uri="${CMEK_SCALR_ISSUER}" \
  --allowed-audiences="${CMEK_GCP_OIDC_AUDIENCE}" \
  --attribute-mapping="google.subject=assertion.sub,attribute.scalr_account_id=assertion.scalr_account_id,attribute.scalr_account_name=assertion.scalr_account_name,attribute.aud=assertion.aud"
```

```bash
echo "${CMEK_GCP_WORKLOAD_PROVIDER_NAME}"
```

---

## 3 · KMS key ring + crypto key (`global`)

```bash
gcloud kms keyrings create "${CMEK_GCP_KEY_RING}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global
```

```bash
gcloud kms keys create "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --purpose encryption \
  --protection-level software
```

```bash
echo "${CMEK_GCP_KMS_KEY_NAME}"
```

---

## 4 · IAM: grant KMS access (pick **Option A** or **Option B**)

### Option A — Direct WIF (Scalr: **omit** `google-service-account-email`)

Grant **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** on the key to a **workload principal** from this pool. No Google service account is required.

**Wide (any Scalr account that can mint a token for this pool):** `--member` uses `…/POOL_ID/*` — every mapped external identity in the pool can use the key.

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "${CMEK_GCP_WIF_PRINCIPAL_SET}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

**Restricted (recommended): one Scalr account only** — e.g. account name `dummy`. Scalr sets `sub` to `account:<name>`; your OIDC provider mapping uses `google.subject=assertion.sub`, so the workload **subject** in IAM is exactly `account:dummy`. Bind that single principal instead of `/*`:

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "${CMEK_GCP_WIF_PRINCIPAL_SINGLE}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

Use **`${CMEK_SCALR_ACCOUNT_NAME}`** (same string as the Scalr account slug). If `gcloud` rejects the member, try URL-encoding the colon in the subject (`account%3A${CMEK_SCALR_ACCOUNT_NAME}`) inside `CMEK_GCP_WIF_PRINCIPAL_SINGLE` or use an **attribute** member instead (matches your mapping `attribute.scalr_account_name=assertion.scalr_account_name`):

`principalSet://iam.googleapis.com/projects/${CMEK_GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${CMEK_GCP_POOL_ID}/attribute.scalr_account_name/${CMEK_SCALR_ACCOUNT_NAME}`

**Negative test (checklist):** remove this binding to confirm encrypt/decrypt fails with a clear error.

---

### Option B — WIF + service account impersonation (Scalr: **set** `google-service-account-email`)

1. Runtime service account (KMS caller after impersonation).

```bash
gcloud iam service-accounts create "${CMEK_GCP_SA_RUNTIME_NAME}" \
  --project "${CMEK_GCP_PROJECT}" \
  --display-name "Scalr CMEK WIF runtime"
```

2. KMS: only this SA needs crypto on the key.

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_RUNTIME}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

3. Allow the WIF pool to impersonate that SA.

```bash
gcloud iam service-accounts add-iam-policy-binding "${CMEK_GCP_SA_RUNTIME}" \
  --project "${CMEK_GCP_PROJECT}" \
  --role roles/iam.workloadIdentityUser \
  --member "${CMEK_GCP_WIF_PRINCIPAL_SET}"
```

Use **`${CMEK_GCP_WIF_PRINCIPAL_SINGLE}`** (or the `attribute.scalr_account_name/...` form) instead of **`${CMEK_GCP_WIF_PRINCIPAL_SET}`** here if you only want that Scalr account to impersonate the runtime SA.

**Negative test (checklist):** drop step 3 (or remove `workloadIdentityUser`) with a valid SA email in Scalr → expect failure when exchanging/using credentials.

---

## 5 · Scalr API (`google-credentials-type` = `oidc`)

Use the same `google-kms-key-name` and `google-workload-provider-name` in both cases.

| JSON:API attribute | Option A (direct WIF) | Option B (WIF + SA) |
|--------------------|----------------------|---------------------|
| `provider-type` | `google-cloud-kms` | `google-cloud-kms` |
| `google-credentials-type` | `oidc` | `oidc` |
| `google-kms-key-name` | `$CMEK_GCP_KMS_KEY_NAME` | `$CMEK_GCP_KMS_KEY_NAME` |
| `google-workload-provider-name` | `$CMEK_GCP_WORKLOAD_PROVIDER_NAME` | `$CMEK_GCP_WORKLOAD_PROVIDER_NAME` |
| `google-service-account-email` | omit or `null` | `$CMEK_GCP_SA_RUNTIME` |

Token claims to assert in tests: `iss` = Scalr hostname (HTTPS issuer), `aud` = `$CMEK_GCP_OIDC_AUDIENCE`, `sub` = `account:<account_name>`, plus `scalr_account_id`, `scalr_account_name`. Token TTL used for issuance is 3600s — cover long-running re-encryption in component tests if applicable.

---

## 6 · Optional: full second stack for side-by-side A/B tests

Duplicate **pool id**, **provider id**, **key id**, and/or **SA name** exports (e.g. suffix `-b`), repeat §1–§5, and attach a **second** Scalr CMEK profile (separate account or lifecycle) so Option A and Option B never share the same pool+key binding rules.

---

## Cleanup · Tear down

Run steps **in an order that matches what you created**. Below: remove IAM, then provider, pool, then KMS versions/keys (key ring itself cannot be deleted in Cloud KMS).

### Option A cleanup (direct WIF on key)

Use the **same** `--member` you used in `add-iam-policy-binding`. Only run **one** of the blocks below.

**Pool-wide binding** (`${CMEK_GCP_WIF_PRINCIPAL_SET}`):

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "${CMEK_GCP_WIF_PRINCIPAL_SET}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

**Single Scalr account** (`${CMEK_GCP_WIF_PRINCIPAL_SINGLE}` — `principal://…/subject/account:…`):

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "${CMEK_GCP_WIF_PRINCIPAL_SINGLE}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

If you used the **`attribute.scalr_account_name/…`** member in §4, pass that **exact** string as `--member` here instead.

### Option B cleanup (SA + `workloadIdentityUser`)

```bash
gcloud iam service-accounts remove-iam-policy-binding "${CMEK_GCP_SA_RUNTIME}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "${CMEK_GCP_WIF_PRINCIPAL_SET}" \
  --role roles/iam.workloadIdentityUser
```

(Use the same member string you used for `add-iam-policy-binding`, e.g. **`${CMEK_GCP_WIF_PRINCIPAL_SINGLE}`** if you tightened it.)

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_RUNTIME}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

```bash
gcloud iam service-accounts delete "${CMEK_GCP_SA_RUNTIME}" \
  --project "${CMEK_GCP_PROJECT}" --quiet
```

### WIF + KMS (shared)

```bash
gcloud iam workload-identity-pools providers delete "${CMEK_GCP_PROVIDER_ID}" \
  --project="${CMEK_GCP_PROJECT}" \
  --location="global" \
  --workload-identity-pool="${CMEK_GCP_POOL_ID}" \
  --quiet
```

```bash
gcloud iam workload-identity-pools delete "${CMEK_GCP_POOL_ID}" \
  --project="${CMEK_GCP_PROJECT}" \
  --location="global" \
  --quiet
```

### Crypto key (optional; after version is `DESTROYED`)

**Cancel** pending version destruction with **`gcloud kms keys versions restore`** (same version id) before the pending window ends; full steps with **`$CMEK_GCP_KMS_KEY_NAME`**: **`cmek-edge-cases.md`** → GCP schedule and cancel version destruction.

```bash
gcloud kms keys versions destroy 1 \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --key "${CMEK_GCP_KEY_ID}"
```

When the version is **`DESTROYED`**, delete the version and key per [Delete Cloud KMS resources](https://cloud.google.com/kms/docs/delete-kms-resources). If `gcloud kms keys delete` is missing, run `gcloud components update` or use `gcloud beta kms keys delete` with the same flags.
