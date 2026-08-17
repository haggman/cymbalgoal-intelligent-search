#!/usr/bin/env bash
#
# CymbalGoal — acceptance test. Run in a VIRGIN Qwiklabs project.
#
# WHERE: Cloud Shell, fresh project, nothing created by hand.
# RUN:   bash 08-acceptance.sh
#
# Self-logging:
#   Full log : ~/cg-08-full.log
#   SUMMARY  : ~/cg-08-summary.txt   <-- send this back
#
# WHY A FRESH PROJECT
# Anything created outside Terraform makes Terraform look more complete than it
# is. The previous project had a hand-made PSA range, six hand-enabled APIs and a
# hand-granted service-agent binding — all of which would mask an omission that
# only surfaces at Start Lab, in front of a room.
#
# WHY APPLY TWICE
# Every serious defect this build hit was invisible on the first happy path:
#   * an invented flag name that killed the whole instance create
#   * a placeholder username AlloyDB accepted without validating
#   * an IAM role list that ONLY failed on the second apply
#   * a notebook that was valid JSON but not a valid notebook
#   * a benchmark that measured an impossible scenario and produced a clean number
# A second apply against unchanged config must be a clean no-op. Anything else is
# drift we would otherwise ship.

set -uo pipefail
FULL=~/cg-08-full.log
SUMMARY=~/cg-08-summary.txt
exec > >(tee "$FULL") 2>&1

TFDIR="${1:-$HOME/cymbalgoal-intelligent-search/terraform}"
cd "$TFDIR" || { echo "no terraform dir at $TFDIR"; exit 1; }

PROJECT=$(gcloud config get-value project)
ACCOUNT=$(gcloud config get-value account)
echo "=============================================="
echo " project : $PROJECT"
echo " account : $ACCOUNT"
echo " tfdir   : $TFDIR"
echo "=============================================="

# ---------------------------------------------------------------------------
echo; echo "### 0. Is this project actually virgin? ###"
# ---------------------------------------------------------------------------
DIRTY=0
if gcloud alloydb clusters list --format='value(name)' 2>/dev/null | grep -q .; then
  echo "  !! an AlloyDB cluster already exists — NOT a clean test"; DIRTY=1
fi
if gcloud compute networks list --format='value(name)' 2>/dev/null | grep -q cymbalgoal; then
  echo "  !! cymbalgoal-network already exists — NOT a clean test"; DIRTY=1
fi
if [ -f terraform.tfstate ] || [ -d .terraform ]; then
  echo "  !! local terraform state present — rm -rf .terraform* for a true cold start"; DIRTY=1
fi
[ "$DIRTY" = "0" ] && echo "  clean"

# ---------------------------------------------------------------------------
echo; echo "### 1. Toolchain must match runtime.yaml ###"
# ---------------------------------------------------------------------------
WANT=$(grep -E '^version:' runtime.yaml | awk '{print $2}')
HAVE=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo "none")
echo "  runtime.yaml wants : $WANT"
echo "  installed          : $HAVE"
[ "$WANT" = "$HAVE" ] || echo "  !! MISMATCH — you are testing a different stack than Start Lab runs"

# ---------------------------------------------------------------------------
echo; echo "### 2. tfvars must contain ONLY platform-injected variables ###"
# ---------------------------------------------------------------------------
# If the apply needs a variable Qwiklabs does not inject, it works here and fails
# at Start Lab. This is the CymbalFlix user_email trap.
ALLOWED="gcp_project_id gcp_region gcp_zone gcp_username"
if [ -f terraform.tfvars ]; then
  while read -r k _; do
    [ -z "$k" ] && continue
    case "$k" in \#*) continue;; esac
    grep -qw -- "$k" <<<"$ALLOWED" || echo "  !! $k is NOT platform-injected — Start Lab will fail"
  done < <(grep -E '^[a-z_]+ *=' terraform.tfvars | sed 's/ *=.*//')
  echo "  declared: $(grep -cE '^[a-z_]+ *=' terraform.tfvars) variables"
else
  echo "  !! no terraform.tfvars — copy terraform.tfvars.example and fill it in"; exit 1
fi

# ---------------------------------------------------------------------------
echo; echo "### 3. init / validate / fmt ###"
# ---------------------------------------------------------------------------
terraform init -input=false          || { echo "INIT FAILED"; exit 1; }
terraform fmt -check -diff           || echo "  (fmt drift — cosmetic)"
terraform validate                   || { echo "VALIDATE FAILED"; exit 1; }

# ---------------------------------------------------------------------------
echo; echo "### 4. FIRST apply — the one everything has passed so far ###"
# ---------------------------------------------------------------------------
T0=$SECONDS
terraform apply -auto-approve -input=false
APPLY1_RC=$?
APPLY1=$((SECONDS-T0))
echo ">>> first apply: ${APPLY1}s, rc=$APPLY1_RC"
[ "$APPLY1_RC" = "0" ] || { echo "FIRST APPLY FAILED — stopping"; exit 1; }

# ---------------------------------------------------------------------------
echo; echo "### 5. SECOND apply — the one that finds what the first hides ###"
# ---------------------------------------------------------------------------
T0=$SECONDS
terraform plan -detailed-exitcode -input=false > /tmp/plan2.txt 2>&1
PLAN_RC=$?
APPLY2=$((SECONDS-T0))
# -detailed-exitcode: 0 = no changes (what we want), 2 = changes pending, 1 = error
case "$PLAN_RC" in
  0) echo ">>> SECOND PLAN CLEAN — no drift (${APPLY2}s)  ✅" ;;
  2) echo ">>> !! SECOND PLAN WANTS CHANGES — this config is NOT idempotent"
     grep -E '^  # |will be|must be replaced' /tmp/plan2.txt | head -20 ;;
  *) echo ">>> !! SECOND PLAN ERRORED"; tail -25 /tmp/plan2.txt ;;
esac

# ---------------------------------------------------------------------------
echo; echo "### 6. Did it build what we expect? ###"
# ---------------------------------------------------------------------------
terraform output

echo; echo "--- cluster ---"
gcloud alloydb clusters describe cymbalgoal-cluster --region=us-central1 \
  --format='value(databaseVersion,state)' 2>/dev/null

echo "--- instance flags (every name must have been verified) ---"
gcloud alloydb instances describe cymbalgoal-primary --cluster=cymbalgoal-cluster \
  --region=us-central1 --format='value(databaseFlags)' 2>/dev/null

echo "--- public ip ---"
gcloud alloydb instances describe cymbalgoal-primary --cluster=cymbalgoal-cluster \
  --region=us-central1 --format='value(publicIpAddress)' 2>/dev/null

echo "--- THE binding: without it every vector search in the lab fails ---"
PROJNUM=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
  --filter="bindings.role=roles/aiplatform.user AND bindings.members:gcp-sa-alloydb" \
  --format="value(bindings.members)" 2>/dev/null | grep -q "service-${PROJNUM}" \
  && echo "  ✅ alloydb service agent has roles/aiplatform.user" \
  || echo "  ❌ MISSING — ai.embedding() will fail from Task 2 onward"

echo "--- student db user ---"
gcloud alloydb users list --cluster=cymbalgoal-cluster --region=us-central1 \
  --format='value(name,userType,databaseRoles)' 2>/dev/null

# ---------------------------------------------------------------------------
{
  echo "===== CymbalGoal 08 — acceptance SUMMARY ====="
  echo
  echo "project: $PROJECT"
  grep -E 'clean|NOT a clean test|local terraform state' "$FULL" | head -4
  echo
  echo "-- toolchain --"
  grep -E 'runtime.yaml wants|installed|MISMATCH' "$FULL"
  echo
  echo "-- tfvars --"
  grep -E 'NOT platform-injected|declared:' "$FULL"
  echo
  echo "-- applies --"
  grep -E 'first apply:|SECOND PLAN' "$FULL"
  echo
  echo "-- built --"
  grep -E 'POSTGRES_18|READY|alloydb service agent|MISSING|ALLOYDB_IAM_USER|alloydbsuperuser' "$FULL" | head -10
  echo
  echo "-- outputs --"
  sed -n '/^alloydb_cluster/,/^instructor_preflight/p' "$FULL" | head -10
  echo
  echo "===== end ====="
} > "$SUMMARY"

echo; echo "=============================================="
cat "$SUMMARY"
echo "=============================================="
echo
echo "NEXT — the half a script cannot check:"
echo "  1. Import notebooks/00-provisioning-prototype.ipynb into a STOCK Colab"
echo "     Enterprise runtime (no VPC attachment). TIME THE COLD START — that is"
echo "     the last unmeasured number in Task 1's cost."
echo "  2. Run it top to bottom with NO manual intervention. Any hand-fix is a"
echo "     step the lab is missing."
echo "  3. Run it a SECOND time. The DROP/terminate path only exists because a"
echo "     re-run is normal student behaviour."
echo
echo "Full log : $FULL"
echo "SUMMARY  : $SUMMARY   <-- send this back"
