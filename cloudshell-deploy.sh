#!/usr/bin/env bash
# =============================================================================================
# Onward Logistics - one-shot AWS CloudShell deployer
#
# Lives in the infra repo. Builds the whole lab from the two GitHub repos (infra + app),
# in the only order that works:
#
#   1. Preflight        account, region, tools, GitHub token
#   2. GitHub repos     make sure the infra and app repos exist (lab needs TWO repos)
#   3. Bootstrap        00-bootstrap stack (GitSync role + CodeConnections GitHub connection)
#   4. Connection       wait for the one-time GitHub authorization (only manual console step)
#   5. Publish infra    clone infra repo, render account/region/connection values, push if changed
#   6. GitSync 01-03    foundation (OIDC, ECR), network (no NAT, endpoints), ALB
#   7. Publish app      clone app repo, render, push -> GitHub Actions (OIDC) builds first image
#   8. Wait for image   ECR :latest must exist before the private ECS service can start
#   9. GitSync 04-06    ECS service, auto scaling, CodeDeploy/CodePipeline/EventBridge
#  10. Verify           ALB responds, no NAT, no 0.0.0.0/0 in private routes, no inline policies
#
# Every step is idempotent: if CloudShell times out, just run the script again.
# Both repos are cloned fresh from GitHub, so push your local edits before running.
# A render commit may be pushed to either repo: 'git pull' your local clones afterwards.
#
# Usage (in AWS CloudShell):
#   git clone https://github.com/<you>/AWS-onward-orders-app-infra.git && cd AWS-onward-orders-app-infra
#   export GITHUB_TOKEN=<classic PAT with scopes: repo, workflow>   # or you will be prompted
#   bash cloudshell-deploy.sh            # full deploy (same as: deploy)
#   bash cloudshell-deploy.sh publish    # only re-render and push both repos
#   bash cloudshell-deploy.sh status     # stack status, URLs, last pipeline run
#   bash cloudshell-deploy.sh verify     # run the security / HA checks again
#   bash cloudshell-deploy.sh teardown   # delete stacks 06 -> 01 (idle costs nothing)
#   Add -y to skip confirmation prompts.
#
# Overridable settings (export before running):
#   AWS_REGION        default: CloudShell region, else eu-west-1
#   PREFIX            default: onward-orders-lab   (must match the templates' ResourcePrefix)
#   GITHUB_OWNER      default: owner of the GitHub token
#   INFRA_REPO        default: AWS-onward-orders-app-infra
#   APP_REPO          default: AWS-onward-orders-app
#   BRANCH            default: main
#   REPO_VISIBILITY   default: public              (public|private)
#   CONNECTION_ARN    reuse an existing AVAILABLE CodeConnections GitHub connection
#   START_PIPELINE    default: true  (release once through the pipeline to prove it end to end)
#   KEEP_BOOTSTRAP    default: true  (teardown keeps the 00 bootstrap stack + connection)
# =============================================================================================
set -Eeuo pipefail
trap 'echo -e "\n\033[31m[FAILED]\033[0m line $LINENO: $BASH_COMMAND\nFix the cause and re-run - completed steps are skipped." >&2' ERR

# ---------- settings -------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # Infra repo checkout (this script's repo)
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"           # Target region
PREFIX="${PREFIX:-onward-orders-lab}"                              # Naming prefix
INFRA_REPO="${INFRA_REPO:-AWS-onward-orders-app-infra}"            # Infra repo name
APP_REPO="${APP_REPO:-AWS-onward-orders-app}"                      # App repo name
BRANCH="${BRANCH:-main}"                                           # Branch everything follows
REPO_VISIBILITY="${REPO_VISIBILITY:-public}"                       # New repo visibility
START_PIPELINE="${START_PIPELINE:-true}"                           # Prove the pipeline once
WORK_DIR="${WORK_DIR:-$HOME/onward-orders-work}"                   # Rendered copies of both repos
LOG_FILE="${LOG_FILE:-$HOME/onward-orders-deploy.log}"             # Full log
BOOTSTRAP_STACK="${PREFIX}-00-bootstrap"                           # One-time CLI stack
SRC_ACCOUNT="648637468459"                                         # Account hardcoded in the source files
SRC_REGION="eu-west-1"                                             # Region hardcoded in the source files
SRC_OWNER="Ndaziramiyep"                                           # GitHub owner hardcoded in the source files
ASSUME_YES=false

export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""

# ---------- output helpers -------------------------------------------------------------------
c_b='\033[1m'; c_g='\033[32m'; c_y='\033[33m'; c_c='\033[36m'; c_0='\033[0m'
step() { echo -e "\n${c_b}${c_c}==> $*${c_0}"; }
ok()   { echo -e "  ${c_g}✔${c_0} $*"; }
warn() { echo -e "  ${c_y}!${c_0} $*"; }
info() { echo -e "    $*"; }
die()  { echo -e "\033[31m✘ $*\033[0m" >&2; exit 1; }
confirm() {
  $ASSUME_YES && return 0
  read -r -p "  $1 [y/N] " ans </dev/tty; [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------- AWS helpers ----------------------------------------------------------------------
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND"
}
stack_out() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text 2>/dev/null || true
}
require_stack_ok() {
  local s; s="$(stack_status "$1")"
  [[ "$s" == CREATE_COMPLETE || "$s" == UPDATE_COMPLETE ]] \
    || die "Stack $1 is $s. Check: CloudFormation > $1 > Events (and Git sync tab)."
  ok "$1: $s"
}

# ---------- GitHub helpers (token is only ever sent to github.com, never stored) -------------
gh_api() {   # gh_api METHOD PATH [JSON]
  local args=(-fsS -X "$1" -H "Authorization: Bearer $GITHUB_TOKEN"
              -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  [[ -n "${3:-}" ]] && args+=(-d "$3")
  curl "${args[@]}" "https://api.github.com$2"
}
gh_code() {  # HTTP status only
  curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" "https://api.github.com$1"
}
git_auth() { # git with the token injected per command (nothing written to .git/config)
  local b64; b64="$(printf '%s:%s' "$GITHUB_LOGIN" "$GITHUB_TOKEN" | base64 -w0)"
  git -c credential.helper= -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $b64" "$@"
}

# =============================================================================================
# 1. Preflight
# =============================================================================================
preflight() {
  step "1. Preflight"
  for t in aws git jq curl sed base64; do command -v "$t" >/dev/null || die "Missing tool: $t"; done
  [[ -d "$ROOT/templates" && -f "$ROOT/bootstrap/00-gitsync-role.yaml" ]] \
    || die "Run this script from a clone of the infra repo (expected templates/ and bootstrap/ next to it)."
  aws codeconnections help >/dev/null 2>&1 || die "AWS CLI too old for 'codeconnections'. Update the AWS CLI v2."

  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || die "No AWS credentials."
  CALLER="$(aws sts get-caller-identity --query Arn --output text)"
  ok "AWS account $ACCOUNT_ID, region $REGION"
  info "Caller: $CALLER"
  if [[ "$REGION" != "$SRC_REGION" ]]; then
    warn "Source files target $SRC_REGION; they will be rendered for $REGION."
  fi
}

github_login() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "  A GitHub token is needed to create and push the two repos."
    echo "  Classic PAT scopes: repo, workflow   (fine-grained: Administration, Contents, Workflows, Actions = RW)"
    read -r -s -p "  GitHub token: " GITHUB_TOKEN </dev/tty; echo
  fi
  local me; me="$(gh_api GET /user)" || die "GitHub token rejected."
  GITHUB_LOGIN="$(jq -r .login <<<"$me")"
  GITHUB_OWNER="${GITHUB_OWNER:-$GITHUB_LOGIN}"
  GIT_EMAIL="$(jq -r '.id' <<<"$me")+${GITHUB_LOGIN}@users.noreply.github.com"
  ok "GitHub user $GITHUB_LOGIN, repos owner $GITHUB_OWNER"
}

# =============================================================================================
# 2. GitHub repositories
# =============================================================================================
ensure_repo() {
  local name="$1" desc="$2"
  if [[ "$(gh_code "/repos/$GITHUB_OWNER/$name")" == 200 ]]; then
    ok "github.com/$GITHUB_OWNER/$name exists"; return
  fi
  local private=false; [[ "$REPO_VISIBILITY" == private ]] && private=true
  local body; body="$(jq -nc --arg n "$name" --arg d "$desc" --argjson p "$private" \
    '{name:$n, description:$d, private:$p, auto_init:false}')"
  if [[ "$GITHUB_OWNER" == "$GITHUB_LOGIN" ]]; then gh_api POST /user/repos "$body" >/dev/null
  else gh_api POST "/orgs/$GITHUB_OWNER/repos" "$body" >/dev/null; fi
  ok "Created github.com/$GITHUB_OWNER/$name ($REPO_VISIBILITY)"
}

# Clones a repo fresh from GitHub, renders the account-specific values, and pushes only if
# that changed something. Sets PUSHED_NEW_COMMIT=true|false.
publish_repo() {
  local name="$1" render_fn="$2" check="$3" dir="$WORK_DIR/$1"
  local url="https://github.com/$GITHUB_OWNER/$name.git"
  rm -rf "$dir"
  git_auth ls-remote --exit-code --heads "$url" "$BRANCH" >/dev/null 2>&1 \
    || die "$url has no '$BRANCH' branch. Push your code to it first, then re-run."
  git_auth clone -q --branch "$BRANCH" "$url" "$dir"
  [[ -e "$dir/$check" ]] || die "$name does not look right: '$check' is missing at the repo root."
  "$render_fn" "$dir"
  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet; then
    PUSHED_NEW_COMMIT=false; ok "$name already has this account's values"
  else
    git -C "$dir" -c user.name="$GITHUB_LOGIN" -c user.email="$GIT_EMAIL" \
      commit -q -m "chore: set account values for $ACCOUNT_ID / $REGION"
    git_auth -C "$dir" push -q origin "$BRANCH"
    PUSHED_NEW_COMMIT=true; ok "Pushed $name -> $url  (run 'git pull' in your local clone)"
  fi
}

# Replace account / region / owner placeholders that are hardcoded in the source files.
render_common() {   # render_common DIR 'glob' ['glob' ...]  (globs are relative to DIR)
  local dir="$1"; shift
  ( cd "$dir"; shopt -s nullglob
    local pat f
    for pat in "$@"; do
      for f in $pat; do
        sed -i -e "s/$SRC_ACCOUNT/$ACCOUNT_ID/g" \
               -e "s/$SRC_REGION/$REGION/g" \
               -e "s#github.com/$SRC_OWNER/#github.com/$GITHUB_OWNER/#g" "$f"
      done
    done )
}

render_infra() {
  local d="$1"
  render_common "$d" 'deployments/*.deployment.yaml' 'scripts/*.sh' '.github/workflows/*.yaml' README.md

  # GitHub owner of the app repo (OIDC trust + pipeline source)
  sed -i "s/^\(  GitHubOrg:\) *[^ #]*/\1 $GITHUB_OWNER/" "$d/deployments/01-foundation.deployment.yaml" \
                                                        "$d/deployments/06-delivery.deployment.yaml"
  sed -i "s/^\(  AppRepo:\) *[^ #]*/\1 $APP_REPO/"      "$d/deployments/01-foundation.deployment.yaml" \
                                                        "$d/deployments/06-delivery.deployment.yaml"
  sed -i "s/^\(  AppBranch:\) *[^ #]*/\1 $BRANCH/"      "$d/deployments/01-foundation.deployment.yaml" \
                                                        "$d/deployments/06-delivery.deployment.yaml"
  # GitHub connection from the bootstrap stack
  sed -i "s#^  ConnectionArn: .*#  ConnectionArn: $CONNECTION_ARN  \# GitHub connection (bootstrap output)#" \
    "$d/deployments/06-delivery.deployment.yaml"
  # Regional S3 prefix list (tasks reach ECR layers in S3 through the gateway endpoint)
  sed -i "s/^\(  S3PrefixListId:\) *[^ #]*/\1 $S3_PREFIX_LIST/" "$d/deployments/02-network.deployment.yaml"
  # An account can only hold one GitHub OIDC provider: reuse it if it already exists
  if [[ -n "$OIDC_REUSE_ARN" ]]; then
    sed -i "/^  ShaImagesToKeep:/a\\  ExistingOidcProviderArn: $OIDC_REUSE_ARN  # Provider already in the account, reused" \
      "$d/deployments/01-foundation.deployment.yaml"
  fi
}

render_app() {
  local d="$1"
  render_common "$d" taskdef.json '.github/workflows/*.yaml' README.md
  sed -i "s/^\(  ECR_REPOSITORY:\) *[^ #]*/\1 $PREFIX/" "$d/.github/workflows/build-push.yaml"
}

# Values the renderers need
discover_values() {
  S3_PREFIX_LIST="$(aws ec2 describe-managed-prefix-lists \
    --filters "Name=prefix-list-name,Values=com.amazonaws.$REGION.s3" \
    --query 'PrefixLists[0].PrefixListId' --output text)"
  [[ "$S3_PREFIX_LIST" == pl-* ]] || die "Could not find the S3 prefix list for $REGION."
  ok "S3 prefix list: $S3_PREFIX_LIST"

  OIDC_REUSE_ARN=""
  local arn="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" >/dev/null 2>&1; then
    # Reuse only if the foundation stack did NOT create it (flipping the condition would delete it)
    if ! aws cloudformation describe-stack-resource --stack-name "$PREFIX-01-foundation" \
         --logical-resource-id GitHubOidcProvider >/dev/null 2>&1; then
      OIDC_REUSE_ARN="$arn"; ok "GitHub OIDC provider already exists - will be reused"
    else
      ok "GitHub OIDC provider is owned by the foundation stack"
    fi
  fi
}

# =============================================================================================
# 3-4. Bootstrap stack + GitHub connection
# =============================================================================================
bootstrap() {
  step "3. Bootstrap stack ($BOOTSTRAP_STACK)"
  local overrides=(ResourcePrefix="$PREFIX")
  if [[ "$(stack_status "$BOOTSTRAP_STACK")" == NOT_FOUND ]]; then
    local existing="${CONNECTION_ARN:-}"
    if [[ -z "$existing" ]]; then   # Reuse an authorised GitHub connection if there is one
      existing="$(aws codeconnections list-connections --provider-type-filter GitHub \
        --query "Connections[?ConnectionStatus=='AVAILABLE'].ConnectionArn | [0]" --output text 2>/dev/null || true)"
      if [[ "$existing" == None ]]; then existing=""; fi
      if [[ -n "$existing" ]]; then ok "Reusing AVAILABLE GitHub connection $existing"; fi
    fi
    overrides+=(ExistingConnectionArn="$existing")
  fi
  # On re-runs, parameters not passed keep their previous values (never flips the connection condition)
  aws cloudformation deploy \
    --stack-name "$BOOTSTRAP_STACK" \
    --template-file "$ROOT/bootstrap/00-gitsync-role.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides "${overrides[@]}" \
    --tags Project=onward-orders Environment=lab Owner=patrick-ndaziramiye \
           CostCenter=amalitech-training ManagedBy=cloudformation Repository="$INFRA_REPO" >/dev/null
  require_stack_ok "$BOOTSTRAP_STACK"
  CONNECTION_ARN="$(stack_out "$BOOTSTRAP_STACK" ConnectionArn)"
  GITSYNC_ROLE_ARN="$(stack_out "$BOOTSTRAP_STACK" GitSyncRoleArn)"
  info "GitSync role: $GITSYNC_ROLE_ARN"
  info "Connection:   $CONNECTION_ARN"

  step "4. GitHub connection authorization"
  local status shown=false
  for _ in $(seq 1 120); do
    status="$(aws codeconnections get-connection --connection-arn "$CONNECTION_ARN" \
      --query Connection.ConnectionStatus --output text)"
    if [[ "$status" == AVAILABLE ]]; then ok "Connection is AVAILABLE"; break; fi
    if ! $shown; then
      warn "Connection is $status. ONE-TIME MANUAL STEP (the only console action in this lab):"
      info "1. Open https://$REGION.console.aws.amazon.com/codesuite/settings/connections?region=$REGION"
      info "2. Select '${CONNECTION_ARN##*/}' (${PREFIX}-github) > Update pending connection"
      info "3. Install / choose the AWS Connector GitHub App with access to:"
      info "     $GITHUB_OWNER/$INFRA_REPO and $GITHUB_OWNER/$APP_REPO  (or 'All repositories')"
      info "Waiting (checks every 15 s, up to 30 min)..."
      shown=true
    fi
    sleep 15
  done
  [[ "$status" == AVAILABLE ]] || die "Connection still $status. Authorize it, then re-run."
}

# =============================================================================================
# 6 / 9. GitSync stacks (reuses the repo's own scripts/gitsync-setup.sh)
# =============================================================================================
gitsync() {
  local names=("$@")
  ( cd "$WORK_DIR/$INFRA_REPO" && \
    AWS_REGION="$REGION" PREFIX="$PREFIX" GITHUB_OWNER="$GITHUB_OWNER" INFRA_REPO="$INFRA_REPO" BRANCH="$BRANCH" \
    bash scripts/gitsync-setup.sh "${names[@]}" )
  local n; for n in "${names[@]}"; do require_stack_ok "$PREFIX-$n"; done
}

# =============================================================================================
# 7-8. First image through GitHub Actions (OIDC)
# =============================================================================================
image_exists() {
  aws ecr describe-images --repository-name "$PREFIX" --image-ids imageTag=latest >/dev/null 2>&1
}
first_image() {
  step "7. Publish app repo (GitHub Actions builds the first image)"
  publish_repo "$APP_REPO" render_app .github/workflows/build-push.yaml
  step "8. Wait for $PREFIX:latest in ECR"
  if image_exists; then ok "Image already in ECR"; return; fi
  if ! $PUSHED_NEW_COMMIT; then
    info "No new commit was pushed - triggering the workflow with workflow_dispatch"
    gh_api POST "/repos/$GITHUB_OWNER/$APP_REPO/actions/workflows/build-push.yaml/dispatches" \
      "{\"ref\":\"$BRANCH\"}" >/dev/null || warn "Dispatch failed - run the workflow from the Actions tab."
  fi
  info "Watch: https://github.com/$GITHUB_OWNER/$APP_REPO/actions"
  for _ in $(seq 1 80); do image_exists && { ok "Image pushed by GitHub Actions"; return; }; sleep 15; done
  die "No :latest image after 20 min. Check the Actions run (OIDC role trust, test failures), then re-run."
}

# =============================================================================================
# 10. Verification
# =============================================================================================
verify() {
  step "10. Verify"
  local alb vpc subnets cluster service
  alb="$(stack_out "$PREFIX-03-alb" LoadBalancerDnsName)"
  vpc="$(stack_out "$PREFIX-02-network" VpcId)"
  subnets="$(stack_out "$PREFIX-02-network" PrivateSubnetIds)"
  cluster="$(stack_out "$PREFIX-04-ecs" ClusterName)"
  service="$(stack_out "$PREFIX-04-ecs" ServiceName)"

  info "Waiting for the ECS service to be stable..."
  aws ecs wait services-stable --cluster "$cluster" --services "$service" \
    && ok "ECS service $service is stable" || warn "Service not stable yet - check ECS > $cluster > $service > Events"

  local running azs
  running="$(aws ecs describe-services --cluster "$cluster" --services "$service" \
    --query 'services[0].runningCount' --output text)"
  azs="$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" --query taskArns --output text \
    | xargs -r aws ecs describe-tasks --cluster "$cluster" --query 'tasks[].availabilityZone' --output text --tasks \
    | tr '\t' '\n' | sort -u | tr '\n' ' ')"
  ok "Running tasks: $running across AZs: ${azs:-n/a}"

  local code
  for _ in $(seq 1 20); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://$alb/health" || true)"
    [[ "$code" == 200 ]] && break; sleep 10
  done
  [[ "$code" == 200 ]] && ok "http://$alb/health -> 200" || warn "http://$alb/health -> $code (targets may still be registering)"
  info "Version: $(curl -s "http://$alb/version" || echo n/a)"

  local nats routes
  nats="$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" "Name=state,Values=pending,available" \
    --query 'length(NatGateways)' --output text)"
  [[ "$nats" == 0 ]] && ok "No NAT gateway in $vpc" || warn "$nats NAT gateway(s) found in $vpc"
  routes="$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnets" \
    --query 'length(RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`][])' --output text)"
  [[ "$routes" == 0 ]] && ok "Private route tables have no 0.0.0.0/0 route" || warn "Default route found in private route tables"

  local inline=0 r
  for r in $(aws iam list-roles --query "Roles[?starts_with(RoleName, '$PREFIX')].RoleName" --output text); do
    (( inline += $(aws iam list-role-policies --role-name "$r" --query 'length(PolicyNames)' --output text) )) || true
  done
  [[ "$inline" == 0 ]] && ok "No inline IAM policies on $PREFIX-* roles" || warn "$inline inline policies found"
  local keys; keys="$(aws iam list-users --query 'length(Users)' --output text)"
  info "IAM users in account: $keys (GitHub uses OIDC, no access keys)"
}

start_pipeline() {
  [[ "$START_PIPELINE" == true ]] || return 0
  local p="$PREFIX-pipeline"
  if [[ "$(aws codepipeline list-pipeline-executions --pipeline-name "$p" \
        --query 'length(pipelineExecutionSummaries)' --output text 2>/dev/null || echo 0)" == 0 ]]; then
    aws codepipeline start-pipeline-execution --name "$p" --query pipelineExecutionId --output text >/dev/null
    ok "Started first pipeline run (blue/green canary takes ~10-15 min)"
  else
    ok "Pipeline has already run"
  fi
  info "https://$REGION.console.aws.amazon.com/codesuite/codepipeline/pipelines/$p/view?region=$REGION"
}

summary() {
  step "Done"
  local alb; alb="$(stack_out "$PREFIX-03-alb" LoadBalancerDnsName)"
  cat <<EOF
  Application:   http://$alb
  Infra repo:    https://github.com/$GITHUB_OWNER/$INFRA_REPO
  App repo:      https://github.com/$GITHUB_OWNER/$APP_REPO
  Pipeline:      https://$REGION.console.aws.amazon.com/codesuite/codepipeline/pipelines/$PREFIX-pipeline/view?region=$REGION
  CodeDeploy:    https://$REGION.console.aws.amazon.com/codesuite/codedeploy/deployments?region=$REGION
  Log file:      $LOG_FILE

  Release:       edit RELEASE_NOTE in app/settings.py in the app repo and push to $BRANCH
                 (first 'git pull' if this run pushed a render commit)
  Bad release:   set FORCE_UNHEALTHY = True and publish -> CodeDeploy rolls back
  Zero downtime: while true; do curl -s http://$alb/version; echo; sleep 1; done
  Scale demo:    for i in \$(seq 200); do curl -s "http://$alb/cpu?seconds=1" >/dev/null & done
  Idle / clean:  bash cloudshell-deploy.sh teardown
EOF
}

# =============================================================================================
# Commands
# =============================================================================================
cmd_deploy() {
  preflight
  github_login
  step "Plan"
  info "Use GitHub repos $GITHUB_OWNER/$INFRA_REPO and $GITHUB_OWNER/$APP_REPO (created $REPO_VISIBILITY if missing)"
  info "Deploy stacks $PREFIX-00 .. 06 in $REGION / account $ACCOUNT_ID (ALB + endpoints + Fargate bill hourly)"
  confirm "Proceed?" || die "Cancelled."

  step "2. GitHub repositories"
  ensure_repo "$INFRA_REPO" "Onward Orders infrastructure - CloudFormation deployed by GitSync"
  ensure_repo "$APP_REPO"   "Onward Orders application - Flask container, GitHub Actions OIDC to ECR"

  bootstrap

  step "5. Publish infra repo"
  discover_values
  publish_repo "$INFRA_REPO" render_infra deployments/01-foundation.deployment.yaml

  step "6. GitSync: foundation, network, ALB"
  gitsync 01-foundation 02-network 03-alb

  first_image

  step "9. GitSync: ECS, auto scaling, delivery pipeline"
  gitsync 04-ecs 05-autoscaling 06-delivery

  verify
  start_pipeline
  summary
}

cmd_publish() {
  preflight; github_login
  [[ "$(stack_status "$BOOTSTRAP_STACK")" != NOT_FOUND ]] || die "Run a full deploy first."
  CONNECTION_ARN="$(stack_out "$BOOTSTRAP_STACK" ConnectionArn)"
  discover_values
  step "Publish infra repo"; publish_repo "$INFRA_REPO" render_infra deployments/01-foundation.deployment.yaml
  step "Publish app repo";   publish_repo "$APP_REPO" render_app .github/workflows/build-push.yaml
  if $PUSHED_NEW_COMMIT; then
    info "GitHub Actions -> ECR -> EventBridge -> CodePipeline will release it."
  fi
}

cmd_status() {
  preflight
  step "Stacks"
  local n
  for n in 00-bootstrap 01-foundation 02-network 03-alb 04-ecs 05-autoscaling 06-delivery; do
    printf "    %-34s %s\n" "$PREFIX-$n" "$(stack_status "$PREFIX-$n")"
  done
  step "Endpoints"
  info "ALB: http://$(stack_out "$PREFIX-03-alb" LoadBalancerDnsName)"
  info "Last pipeline run: $(aws codepipeline list-pipeline-executions --pipeline-name "$PREFIX-pipeline" \
    --max-items 1 --query 'pipelineExecutionSummaries[0].[status,lastUpdateTime]' --output text 2>/dev/null || echo n/a)"
}

empty_bucket() {
  local b="$1" json objs
  [[ -n "$b" && "$b" != None ]] || return 0
  aws s3api head-bucket --bucket "$b" 2>/dev/null || return 0
  info "Emptying versioned bucket $b"
  while :; do
    json="$(aws s3api list-object-versions --bucket "$b" --max-items 1000 --output json)"
    objs="$(jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId}) | .[:1000]), Quiet: true}' <<<"$json")"
    [[ "$(jq '.Objects | length' <<<"$objs")" -gt 0 ]] || break
    aws s3api delete-objects --bucket "$b" --delete "$objs" >/dev/null
  done
}

cmd_teardown() {
  preflight
  warn "This deletes stacks $PREFIX-06 .. 01 in $REGION (GitHub repos are kept)."
  if [[ "${KEEP_BOOTSTRAP:-true}" == false ]]; then
    warn "KEEP_BOOTSTRAP=false: the bootstrap stack is deleted too."
  fi
  confirm "Delete the environment?" || die "Cancelled."
  empty_bucket "$(stack_out "$PREFIX-06-delivery" ArtifactBucketName)"
  AWS_REGION="$REGION" PREFIX="$PREFIX" KEEP_BOOTSTRAP="${KEEP_BOOTSTRAP:-true}" \
    bash "$ROOT/scripts/teardown.sh"
}

# ---------- entry point ----------------------------------------------------------------------
CMD="deploy"
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=true ;;
    deploy|publish|status|verify|teardown) CMD="$a" ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) die "Unknown argument: $a (try --help)" ;;
  esac
done

mkdir -p "$WORK_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "---- $(date -u +%FT%TZ) cloudshell-deploy.sh $CMD ----"
case "$CMD" in
  deploy)   cmd_deploy ;;
  publish)  cmd_publish ;;
  status)   cmd_status ;;
  verify)   preflight; verify ;;
  teardown) cmd_teardown ;;
esac
