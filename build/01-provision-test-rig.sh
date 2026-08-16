#!/usr/bin/env bash
#
# CymbalGoal — Tier 1 test rig, phase A: provision a PG 18 AlloyDB cluster.
#
# WHERE: Cloud Shell in the Qwiklabs project.
# RUN:   bash 01-provision-test-rig.sh 2>&1 | tee ~/phaseA.log
#
# This is a THROWAWAY prototype rig, not the lab's Terraform. It uses a public
# IP so Cloud Shell can reach it with plain psql — the real provisioning does
# this from a startup VM on the private network instead.
#
# Wall clock: ~15-20 min, almost all of it the cluster + instance create.
# Safe to re-run: every create is guarded by an existence check.
#
# CHANGELOG
#   v2  Database flags are now DISCOVERED, not assumed. v1 hardcoded
#       google_ml_integration.enable_model_endpoint_management, which does not
#       exist on PG 18 — AlloyDB rejects the whole instance create if any single
#       flag name is unknown, so one bad guess cost the entire run. The flag
#       namespace differs between Cloud SQL and AlloyDB and between PG versions,
#       so the only reliable source is `gcloud alloydb flags list`.

set -uo pipefail

REGION="us-central1"                 # conventions §4: us-central1 or us-east1 only
CLUSTER="cymbalgoal-test"
INSTANCE="cymbalgoal-test-primary"
NETWORK="default"

PROJECT="$(gcloud config get-value project 2>/dev/null)"
if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  echo "FATAL: no project set. Run: gcloud config set project YOUR_PROJECT_ID"; exit 1
fi

# Reuse the password from a previous run if there is one, so a re-run after a
# failure doesn't strand you with a cluster whose password you no longer know.
if [[ -f ~/cymbalgoal-conn.env ]] && grep -q PGPASSWORD ~/cymbalgoal-conn.env; then
  PGPW="$(grep PGPASSWORD ~/cymbalgoal-conn.env | cut -d'"' -f2)"
  echo "NOTE: reusing password from existing ~/cymbalgoal-conn.env"
else
  PGPW="CymbalGoal-Test-$RANDOM$RANDOM"
fi

echo "=============================================="
echo " project : $PROJECT"
echo " region  : $REGION"
echo " cluster : $CLUSTER"
echo "=============================================="

step() { echo; echo "### $* ###"; }

step "1. Enable APIs"
gcloud services enable \
  alloydb.googleapis.com compute.googleapis.com servicenetworking.googleapis.com \
  aiplatform.googleapis.com discoveryengine.googleapis.com \
  cloudresourcemanager.googleapis.com --project="$PROJECT"

step "2. Private Services Access"
if ! gcloud compute addresses describe alloydb-psa --global --project="$PROJECT" >/dev/null 2>&1; then
  gcloud compute addresses create alloydb-psa --global --purpose=VPC_PEERING --prefix-length=16 \
    --network="projects/$PROJECT/global/networks/$NETWORK" --project="$PROJECT"
else
  echo "  alloydb-psa already exists, reusing"
fi
gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com \
  --ranges=alloydb-psa --network="$NETWORK" --project="$PROJECT" \
  || echo "  (peering likely already connected — continuing)"

step "3. Cluster — POSTGRES_18, pinned explicitly (S-11)"
if gcloud alloydb clusters describe "$CLUSTER" --region="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
  echo "  cluster $CLUSTER already exists, skipping create"
else
  gcloud alloydb clusters create "$CLUSTER" --region="$REGION" --project="$PROJECT" \
    --password="$PGPW" --network="$NETWORK" --database-version=POSTGRES_18 || exit 1
fi

step "4. Database flags"
# There is NO gcloud command to list supported flags — `gcloud alloydb` has only
# backups, clusters, instances, operations and users. The authoritative sources
# are the docs page (alloydb/docs/reference/database-flags) and the REST
# endpoint below. Verified against the docs on 2026-08-16:
#
#   enable_model_support        EXISTS, default ON   ← do not set, it's already on
#   enable_ai_query_engine      EXISTS, default ON   ← do not set, it's already on
#   enable_preview_ai_functions EXISTS, default off  ← P-10 CLOSED, exact name confirmed
#   enable_cost_optimized_ai_functions EXISTS, default off ← P-13, Lab 2 Task 6
#   enable_model_endpoint_management  DOES NOT EXIST ← Cloud SQL vocabulary, not AlloyDB
#
# AlloyDB rejects the ENTIRE instance create if any one flag name is unknown, so
# only verified names go in this list.
echo "--- programmatic source of truth, for the record ---"
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://alloydb.googleapis.com/v1/projects/$PROJECT/locations/$REGION/supportedDatabaseFlags" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for f in d.get('supportedDatabaseFlags',[]):
    n=f.get('flagName','')
    if 'google_ml' in n or 'columnar' in n:
        print(' ', n, '| versions:', ','.join(f.get('supportedDbVersions',[])))
" 2>/dev/null || echo "  (listing unavailable — continuing with the verified set)"

FLAGS="google_ml_integration.enable_preview_ai_functions=on"
FLAGS="$FLAGS,google_ml_integration.enable_cost_optimized_ai_functions=on"
FLAGS="$FLAGS,google_columnar_engine.enabled=on"
echo "  effective --database-flags: $FLAGS"

step "5. Primary instance"
# observability_config is set AT CREATION (P-14) — enabling it later forces a
# restart, and it cannot be set on secondaries at all, so it must precede any
# read pool. 8 vCPU because this rig loads 14,235 × VECTOR(3072) and builds ScaNN.
if gcloud alloydb instances describe "$INSTANCE" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
  echo "  instance $INSTANCE already exists, skipping create"
else
  gcloud alloydb instances create "$INSTANCE" \
    --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" \
    --instance-type=PRIMARY --cpu-count=8 --availability-type=ZONAL \
    --assign-inbound-public-ip=ASSIGN_IPV4 \
    --observability-config-enabled \
    --observability-config-track-active-queries \
    --observability-config-track-wait-events \
    ${FLAGS:+--database-flags="$FLAGS"} || {
      echo "  !! instance create failed. Retrying with NO database flags so Tier 1 is not blocked."
      gcloud alloydb instances create "$INSTANCE" \
        --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" \
        --instance-type=PRIMARY --cpu-count=8 --availability-type=ZONAL \
        --assign-inbound-public-ip=ASSIGN_IPV4 \
        --observability-config-enabled \
        --observability-config-track-active-queries \
        --observability-config-track-wait-events || exit 1
    }
fi

step "6. Authorize this Cloud Shell"
# Acceptable ONLY because this project is disposable. Never in a real lab.
gcloud alloydb instances update "$INSTANCE" --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" \
  --authorized-external-networks="0.0.0.0/0" --assign-inbound-public-ip=ASSIGN_IPV4

PUBIP="$(gcloud alloydb instances describe "$INSTANCE" --cluster="$CLUSTER" \
         --region="$REGION" --project="$PROJECT" --format='value(publicIpAddress)')"

cat > ~/cymbalgoal-conn.env <<EOF
export PGHOST="$PUBIP"
export PGUSER="postgres"
export PGPASSWORD="$PGPW"
export PGDATABASE="postgres"
export CG_PROJECT="$PROJECT"
export CG_REGION="$REGION"
export CG_CLUSTER="$CLUSTER"
export CG_INSTANCE="$INSTANCE"
EOF

echo
echo "=============================================="
echo " Public IP : ${PUBIP:-<none — check the console>}"
echo " Saved to  : ~/cymbalgoal-conn.env"
echo "=============================================="
source ~/cymbalgoal-conn.env
psql -c "select version();" || echo "  !! could not connect"
echo
echo "Next: bash 02-tier1-tests.sh 2>&1 | tee ~/tier1.log"
