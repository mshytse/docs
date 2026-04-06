# GCP CMEK OIDC / Workload Identity (test setup)

Scalr issues an OIDC ID token (`taco/app/encryption/service/oidc.py`: `iss`, `aud`, `sub`, `scalr_account_id`, `scalr_account_name`). GCP **Workload Identity Federation** trusts that issuer; the token audience Scalr uses for GCP is:

`//iam.googleapis.com/{google-workload-provider-name}`

(i.e. `//iam.googleapis.com/projects/.../locations/global/workloadIdentityPools/.../providers/...` — see `taco/app/encryption/v1/factory.py`.)

| Variable | Meaning |
|----------|---------|
| `CMEK_GCP_PROJECT` | Project number or id for pool + provider (commands use project id unless noted) |
| `CMEK_GCP_PROJECT_NUMBER` | Project **number** (required in WIF resource paths) |
| `CMEK_GCP_POOL_ID` | Workload identity pool id |
| `CMEK_GCP_PROVIDER_ID` | OIDC provider id in that pool |
| `CMEK_SCALR_HOSTNAME` | Scalr host only (same as browser URL host, no scheme) |
| `CMEK_SCALR_ISSUER` | `https://${CMEK_SCALR_HOSTNAME}` |
| `CMEK_GCP_SA_RUNTIME` | Optional: SA to impersonate after WIF (for KMS); omit if you bind KMS directly to WIF principal |
| `CMEK_GCP_KEY_RING` / `CMEK_GCP_KEY_ID` | KMS key ids (`global`) |
| `CMEK_GCP_KMS_KEY_NAME` | Full key resource name for Scalr |
| `CMEK_GCP_OIDC_AUDIENCE` | STS/JWT audience `//iam.googleapis.com/` + workload provider path |

```bash
export CMEK_GCP_PROJECT="your-project-id"
export CMEK_GCP_PROJECT_NUMBER="$(gcloud projects describe "${CMEK_GCP_PROJECT}" --format='value(projectNumber)')"
export CMEK_GCP_POOL_ID="scalr-cmek-pool"
export CMEK_GCP_PROVIDER_ID="scalr-cmek-oidc"
export CMEK_SCALR_HOSTNAME="your-env.scalr.io"
export CMEK_SCALR_ISSUER="https://${CMEK_SCALR_HOSTNAME}"
export CMEK_GCP_KEY_RING="scalr-cmek-ring"
export CMEK_GCP_KEY_ID="scalr-cmek-key"
export CMEK_GCP_SA_RUNTIME="cmek-wif@${CMEK_GCP_PROJECT}.iam.gserviceaccount.com"
export CMEK_GCP_WORKLOAD_PROVIDER_NAME="projects/${CMEK_GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${CMEK_GCP_POOL_ID}/providers/${CMEK_GCP_PROVIDER_ID}"
export CMEK_GCP_OIDC_AUDIENCE="//iam.googleapis.com/${CMEK_GCP_WORKLOAD_PROVIDER_NAME}"
export CMEK_GCP_KMS_KEY_NAME="projects/${CMEK_GCP_PROJECT}/locations/global/keyRings/${CMEK_GCP_KEY_RING}/cryptoKeys/${CMEK_GCP_KEY_ID}"
```

Scalr sets JWT `aud` to `$CMEK_GCP_OIDC_AUDIENCE` (see `taco/app/encryption/v1/factory.py`).

---

## 1 · Pool

```bash
gcloud iam workload-identity-pools create "${CMEK_GCP_POOL_ID}" \
  --project="${CMEK_GCP_PROJECT}" \
  --location="global" \
  --display-name="Scalr CMEK"
```

---

## 2 · OIDC provider (Scalr issuer)

Allowed audiences must include the audience string you will configure for the workload provider (often the default for that provider). Map token claims into Google credentials (adjust names to match your pool provider UI / `gcloud` flags).

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

## 3 · KMS key (global)

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

---

## 4 · IAM: who may call KMS

**Option A — impersonate a runtime SA (typical)**

```bash
gcloud iam service-accounts create cmek-wif \
  --project "${CMEK_GCP_PROJECT}" \
  --display-name "Scalr CMEK WIF runtime"
```

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_RUNTIME}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

```bash
gcloud iam service-accounts add-iam-policy-binding "${CMEK_GCP_SA_RUNTIME}" \
  --project "${CMEK_GCP_PROJECT}" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${CMEK_GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${CMEK_GCP_POOL_ID}/*"
```

**Option B — bind `principalSet` for the pool directly on the key** (if your org allows; tighten `/*` to a provider or attribute filter).

---

## 5 · Scalr (OIDC credentials type)

| JSON:API attribute | Value |
|--------------------|--------|
| `provider-type` | `google-cloud-kms` |
| `google-credentials-type` | `oidc` |
| `google-kms-key-name` | `$CMEK_GCP_KMS_KEY_NAME` |
| `google-workload-provider-name` | `$CMEK_GCP_WORKLOAD_PROVIDER_NAME` (resource path only; Scalr uses `//iam.googleapis.com/` + this path as the JWT `aud`) |
| `google-service-account-email` | `$CMEK_GCP_SA_RUNTIME` if you use impersonation (optional in API; omit if not used) |

Token claims Scalr sets: `sub` = `account:<scalr-account-name>`, plus `scalr_account_id`, `scalr_account_name`. Use them in provider **attribute conditions** / IAM bindings as needed.

---

## Cleanup · Tear down

Remove pool provider, pool, SA bindings, and KMS resources in reverse dependency order for your org.

```bash
gcloud iam workload-identity-pools providers delete "${CMEK_GCP_PROVIDER_ID}" \
  --project="${CMEK_GCP_PROJECT}" \
  --location="global" \
  --workload-identity-pool="${CMEK_GCP_POOL_ID}" --quiet
```

```bash
gcloud iam workload-identity-pools delete "${CMEK_GCP_POOL_ID}" \
  --project="${CMEK_GCP_PROJECT}" \
  --location="global" --quiet
```

---

## Reference

- WIF: [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- `taco/app/encryption/v1/factory.py` (OIDC audience `//iam.googleapis.com/...`)
- `taco/app/encryption/service/oidc.py` (JWT claims)
- `taco/openapi/openapi-internal.yml` (`google-workload-provider-name`, `google-credentials-type: oidc`)
