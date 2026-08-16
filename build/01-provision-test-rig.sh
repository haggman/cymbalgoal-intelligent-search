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
# Everything is idempotent enough to re-run after a failure.

set -uo pipefail

REGION="us-central1"                 # conventions §4: us-central1 or us-east1 only
CLUSTER="cymbalgoal-test"
INSTANCE="cymbalgoal-test-primary"
PGPW="CymbalGoal-Test-$RANDOM$RANDOM"
NETWORK="default"

PROJECT="$(gcloud config get-value project 2>/dev/null)"
if [[ -z "$PROJECT" || "$PROJECT" == "(unset)" ]]; then
  echo "FATAL: no project set. Run: gcloud config set project YOUR_PROJECT_ID"; exit 1
fi
PROJECT_NUM="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"

echo "=============================================="
echo " project : $PROJECT ($PROJECT_NUM)"
echo " region  : $REGION"
echo " cluster : $CLUSTER"
echo "=============================================="

step() { echo; echo "### $* ###"; }

step "1. Enable APIs"
# discoveryengine is here because D-09's semantic-reranker form of ai.rank()
# draws its models from it. If that turns out to be wrong, we drop it later.
gcloud services enable \
  alloydb.googleapis.com \
  compute.googleapis.com \
  servicenetworking.googleapis.com \
  aiplatform.googleapis.com \
  discoveryengine.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT"

step "2. Private Services Access (AlloyDB requires it even with a public IP)"
if ! gcloud compute addresses describe alloydb-psa --global --project="$PROJECT" >/dev/null 2>&1; then
  gcloud compute addresses create alloydb-psa \
    --global --purpose=VPC_PEERING --prefix-length=16 \
    --network="projects/$PROJECT/global/networks/$NETWORK" --project="$PROJECT"
else
  echo "  alloydb-psa range already exists, reusing"
fi

# This one is expected to fail harmlessly if the peering is already there.
gcloud services vpc-peerings connect \
  --service=servicenetworking.googleapis.com \
  --ranges=alloydb-psa \
  --network="$NETWORK" --project="$PROJECT" || echo "  (peering likely already connected — continuing)"

step "3. Create the cluster — POSTGRES_18, pinned explicitly (S-11)"
gcloud alloydb clusters create "$CLUSTER" \
  --region="$REGION" --project="$PROJECT" \
  --password="$PGPW" \
  --network="$NETWORK" \
  --database-version=POSTGRES_18

echo "  cluster create exit: $?"

step "4. Create the primary instance"
# 8 vCPU: this rig has to load 14,235 rows of VECTOR(3072) and then build ScaNN
# over them. Undersizing here just makes every measurement slower and less
# representative of what a student cluster will do.
#
# observability_config equivalents are set AT CREATION (P-14) — enabling them
# later forces a restart, which is exactly what we're trying to learn to avoid.
gcloud alloydb instances create "$INSTANCE" \
  --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" \
  --instance-type=PRIMARY \
  --cpu-count=8 \
  --availability-type=ZONAL \
  --assign-inbound-public-ip=ASSIGN_IPV4 \
  --observability-config-enabled \
  --observability-config-track-active-queries \
  --observability-config-track-wait-events \
  --database-flags=google_ml_integration.enable_model_endpoint_management=on

echo "  instance create exit: $?"

step "5. Authorize this Cloud Shell to connect"
MYIP="$(curl -s https://ifconfig.me || curl -s https://api.ipify.org)"
echo "  Cloud Shell egress IP: $MYIP"
# Cloud Shell's egress IP changes between sessions. Widening this is acceptable
# ONLY because this is a disposable Qwiklabs project with throwaway data.
gcloud alloydb instances update "$INSTANCE" \
  --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" \
  --authorized-external-networks="0.0.0.0/0" \
  --assign-inbound-public-ip=ASSIGN_IPV4

step "6. Report connection details"
PUBIP="$(gcloud alloydb instances describe "$INSTANCE" \
  --cluster="$CLUSTER" --region="$REGION" --project="$PROJECT" \
  --format='value(publicIpAddress)')"

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
echo " Public IP : $PUBIP"
echo " Password  : $PGPW"
echo " Saved to  : ~/cymbalgoal-conn.env"
echo "=============================================="
echo
echo "Smoke test:"
source ~/cymbalgoal-conn.env
psql -c "select version();" || echo "  !! could not connect — check the public IP + authorized networks"

echo
echo "Next: bash 02-tier1-tests.sh 2>&1 | tee ~/tier1.log"
