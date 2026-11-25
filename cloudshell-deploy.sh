#!/usr/bin/env bash
# Onward Logistics - one-shot AWS CloudShell deployer.

# Strict mode; any failure reports the line and stops.
set -Eeuo pipefail
trap 'echo -e "\n\033[31m[FAILED]\033[0m line $LINENO: $BASH_COMMAND\nFix the cause and re-run - completed steps are skipped." >&2' ERR

# Settings, overridable through the environment.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
PREFIX="${PREFIX:-onward-orders-lab}"
INFRA_REPO="${INFRA_REPO:-AWS-onward-orders-app-infra}"
APP_REPO="${APP_REPO:-AWS-onward-orders-app}"
BRANCH="${BRANCH:-main}"
REPO_VISIBILITY="${REPO_VISIBILITY:-public}"
START_PIPELINE="${START_PIPELINE:-true}"
WORK_DIR="${WORK_DIR:-$HOME/onward-orders-work}"
LOG_FILE="${LOG_FILE:-$HOME/onward-orders-deploy.log}"
BOOTSTRAP_STACK="${PREFIX}-00-bootstrap"
ASSUME_YES=false

# Values hardcoded in the committed files; render_common rewrites them for the target account.
SRC_ACCOUNT="648637468459"
SRC_REGION="eu-west-1"
SRC_OWNER="Ndaziramiyep"

# Every AWS CLI call targets the chosen region with no pager.
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""

# Terminal colours.
c_b='\033[1m'; c_g='\033[32m'; c_y='\033[33m'; c_c='\033[36m'; c_0='\033[0m'

# Output helpers: step heading, success, warning, detail, and fatal error.
step() { echo -e "\n${c_b}${c_c}==> $*${c_0}"; }
ok()   { echo -e "  ${c_g}✔${c_0} $*"; }
warn() { echo -e "  ${c_y}!${c_0} $*"; }
info() { echo -e "    $*"; }
die()  { echo -e "\033[31m✘ $*\033[0m" >&2; exit 1; }

# Asks for a yes/no answer unless -y was given.
confirm() {
  $ASSUME_YES && return 0
  read -r -p "  $1 [y/N] " ans </dev/tty
  [[ "$ans" =~ ^[Yy]$ ]]
}

# Prints the header comment of this file as help text.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

# Prints a stack's status, or NOT_FOUND.
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND"
}

# Prints one output value of a stack.
stack_out() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text 2>/dev/null || true
}

# Stops the script unless the stack is CREATE_COMPLETE or UPDATE_COMPLETE.
require_stack_ok() {
  local s
  s="$(stack_status "$1")"
  [[ "$s" == CREATE_COMPLETE || "$s" == UPDATE_COMPLETE ]] \
    || die "Stack $1 is $s. Check: CloudFormation > $1 > Events (and Git sync tab)."
  ok "$1: $s"
}

# Set to true by github_login when GITHUB_TOKEN is present.
HAVE_TOKEN=false

# Calls the GitHub REST API: gh_api METHOD PATH [JSON]. The token is only ever sent to github.com.
gh_api() {
  local args=(-fsS -X "$1" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  $HAVE_TOKEN && args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  [[ -n "${3:-}" ]] && args+=(-d "$3")
  curl "${args[@]}" "https://api.github.com$2"
}

# Prints only the HTTP status of a GitHub API GET.
gh_code() {
  local args=(-s -o /dev/null -w '%{http_code}' -H "Accept: application/vnd.github+json")
  $HAVE_TOKEN && args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl "${args[@]}" "https://api.github.com$1"
}

# Runs git with the token injected per command; nothing is written to .git/config.
git_auth() {
  if ! $HAVE_TOKEN; then
    git -c credential.helper= "$@"
    return
  fi
  local b64
  b64="$(printf '%s:%s' "$GITHUB_LOGIN" "$GITHUB_TOKEN" | base64 -w0)"
  git -c credential.helper= -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $b64" "$@"
}

# Step 1: checks tools, AWS credentials and region.
preflight() {
  step "1. Preflight"
  for t in aws git jq curl sed base64; do
    command -v "$t" >/dev/null || die "Missing tool: $t"
  done
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

# Identifies the GitHub user from GITHUB_TOKEN, or falls back to anonymous reads of public repos.
github_login() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    GITHUB_LOGIN=""
    GITHUB_OWNER="${GITHUB_OWNER:-$SRC_OWNER}"
    ok "No GITHUB_TOKEN: reading public repos of $GITHUB_OWNER anonymously"
    info "If a repo needs a change, the script stops and shows it, so you can push it yourself."
    return
  fi
  HAVE_TOKEN=true
  local me
  me="$(gh_api GET /user)" || die "GitHub token rejected."
  GITHUB_LOGIN="$(jq -r .login <<<"$me")"
  GITHUB_OWNER="${GITHUB_OWNER:-$GITHUB_LOGIN}"
  GIT_EMAIL="$(jq -r '.id' <<<"$me")+${GITHUB_LOGIN}@users.noreply.github.com"
  ok "GitHub user $GITHUB_LOGIN, repos owner $GITHUB_OWNER"
}

# Step 2: creates a GitHub repo if it does not exist.
ensure_repo() {
  local name="$1" desc="$2"
  if [[ "$(gh_code "/repos/$GITHUB_OWNER/$name")" == 200 ]]; then
    ok "github.com/$GITHUB_OWNER/$name exists"
    return
  fi
  $HAVE_TOKEN || die "github.com/$GITHUB_OWNER/$name not found (or private). Create and push it, or export GITHUB_TOKEN."

  local private=false
  [[ "$REPO_VISIBILITY" == private ]] && private=true
  local body
  body="$(jq -nc --arg n "$name" --arg d "$desc" --argjson p "$private" \
    '{name:$n, description:$d, private:$p, auto_init:false}')"
  if [[ "$GITHUB_OWNER" == "$GITHUB_LOGIN" ]]; then
    gh_api POST /user/repos "$body" >/dev/null
  else
    gh_api POST "/orgs/$GITHUB_OWNER/repos" "$body" >/dev/null
  fi
  ok "Created github.com/$GITHUB_OWNER/$name ($REPO_VISIBILITY)"
}

# Clones a repo fresh, renders account-specific values, and pushes only if that changed something. Sets PUSHED_NEW_COMMIT=true|false.
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
    PUSHED_NEW_COMMIT=false
    ok "$name already has this account's values"
  elif ! $HAVE_TOKEN; then
    warn "$name needs these account-specific changes, and GitSync reads them from GitHub:"
    git -C "$dir" --no-pager diff --cached
    die "Make the changes above in your local clone of $name, push to $BRANCH, then re-run (or export GITHUB_TOKEN)."
  else
    git -C "$dir" -c user.name="$GITHUB_LOGIN" -c user.email="$GIT_EMAIL" \
      commit -q -m "chore: set account values for $ACCOUNT_ID / $REGION"
    git_auth -C "$dir" push -q origin "$BRANCH"
    PUSHED_NEW_COMMIT=true
    ok "Pushed $name -> $url  (run 'git pull' in your local clone)"
  fi
}

# Rewrites the hardcoded account, region and owner in the given globs: render_common DIR 'glob' ['glob' ...].
render_common() {
  local dir="$1"
  shift
  (
    cd "$dir"
    shopt -s nullglob
    local pat f
    for pat in "$@"; do
      for f in $pat; do
        sed -i -e "s/$SRC_ACCOUNT/$ACCOUNT_ID/g" \
               -e "s/$SRC_REGION/$REGION/g" \
               -e "s#github.com/$SRC_OWNER/#github.com/$GITHUB_OWNER/#g" "$f"
      done
    done
  )
}

# Renders the infra repo's deployment files. An account holds only one GitHub OIDC provider, so an existing one is reused.
render_infra() {
  local d="$1"
  local foundation="$d/deployments/01-foundation.deployment.yaml"
  local network="$d/deployments/02-network.deployment.yaml"

  render_common "$d" 'deployments/*.deployment.yaml' '.github/workflows/*.yaml' README.md

  sed -i "s/^\(  GitHubOrg:\) *[^ #]*/\1 $GITHUB_OWNER/" "$foundation"
  sed -i "s/^\(  AppRepo:\) *[^ #]*/\1 $APP_REPO/"      "$foundation"
  sed -i "s/^\(  AppBranch:\) *[^ #]*/\1 $BRANCH/"      "$foundation"
  sed -i "s/^\(  S3PrefixListId:\) *[^ #]*/\1 $S3_PREFIX_LIST/" "$network"

  if [[ -n "$OIDC_REUSE_ARN" ]]; then
    sed -i "/^  AppBranch:/a\\  ExistingOidcProviderArn: $OIDC_REUSE_ARN" "$foundation"
  fi
}

# Renders the app repo's release settings (scripts/config.sh) and AWS login action.
# The app repo has no task definition: CI copies the latest revision in ECS into the deploy bundle.
render_app() {
  local d="$1"
  render_common "$d" scripts/config.sh .github/actions/aws-login/action.yaml \
    '.github/workflows/*.yaml' README.md
  sed -i -e "s/\(ECR_REPOSITORY:-\)[^}]*/\1$PREFIX/" \
         -e "s/\(PIPELINE_NAME:-\)[^}]*/\1$PREFIX-pipeline/" \
         -e "s/\(BUNDLE_BUCKET:-\)[^}]*/\1$PREFIX-bundle-$ACCOUNT_ID-$REGION/" \
         -e "s/\(TASK_FAMILY:-\)[^}]*/\1$PREFIX/" "$d/scripts/config.sh"
  sed -i "s#role/[a-z0-9-]*-github-actions-role#role/$PREFIX-github-actions-role#" \
    "$d/.github/actions/aws-login/action.yaml"
}

# Finds the regional S3 prefix list and whether to reuse an OIDC provider (only if the foundation stack did not create it, since flipping the condition would delete it).
discover_values() {
  S3_PREFIX_LIST="$(aws ec2 describe-managed-prefix-lists \
    --filters "Name=prefix-list-name,Values=com.amazonaws.$REGION.s3" \
    --query 'PrefixLists[0].PrefixListId' --output text)"
  [[ "$S3_PREFIX_LIST" == pl-* ]] || die "Could not find the S3 prefix list for $REGION."
  ok "S3 prefix list: $S3_PREFIX_LIST"

  OIDC_REUSE_ARN=""
  local arn="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" >/dev/null 2>&1; then
    if ! aws cloudformation describe-stack-resource --stack-name "$PREFIX-01-foundation" \
         --logical-resource-id GitHubOidcProvider >/dev/null 2>&1; then
      OIDC_REUSE_ARN="$arn"
      ok "GitHub OIDC provider already exists - will be reused"
    else
      ok "GitHub OIDC provider is owned by the foundation stack"
    fi
  fi
}

# Steps 3-4: deploys the bootstrap stack and waits for the GitHub connection. On re-runs, unpassed parameters keep their values, so the connection condition never flips.
bootstrap() {
  step "3. Bootstrap stack ($BOOTSTRAP_STACK)"
  local overrides=(ResourcePrefix="$PREFIX")

  if [[ "$(stack_status "$BOOTSTRAP_STACK")" == NOT_FOUND ]]; then
    local existing="${CONNECTION_ARN:-}"
    if [[ -z "$existing" ]]; then
      existing="$(aws codeconnections list-connections --provider-type-filter GitHub \
        --query "Connections[?ConnectionStatus=='AVAILABLE'].ConnectionArn | [0]" --output text 2>/dev/null || true)"
      if [[ "$existing" == None ]]; then
        existing=""
      fi
      if [[ -n "$existing" ]]; then
        ok "Reusing AVAILABLE GitHub connection $existing"
      fi
    fi
    overrides+=(ExistingConnectionArn="$existing")
  fi

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
    if [[ "$status" == AVAILABLE ]]; then
      ok "Connection is AVAILABLE"
      break
    fi
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

# Prints "Key=Value" for each entry of a top-level section (parameters or tags) of a deployment file.
deployment_section() {
  awk -v sec="$1" '
    $0 ~ "^"sec":" { on = 1; next }
    /^[^ #]/       { on = 0 }
    on && /^  [A-Za-z0-9]+:/ {
      line = $0; sub(/[ \t]+#.*$/, "", line); sub(/^  /, "", line)
      key = line; sub(/:.*/, "", key)
      val = line; sub(/^[^:]*:[ \t]*/, "", val); gsub(/^"|"$/, "", val)
      print key "=" val
    }' "$2"
}

# Steps 6 and 9: hands each named stack to GitSync, in order, and waits for it.
# GitSync only updates stacks, so a missing stack is created once from its deployment file
# (same template, parameters and tags). Existing stacks and sync configurations are reused.
gitsync() {
  local n stack file tpl link_id params tags
  link_id="$(aws codeconnections list-repository-links \
    --query "RepositoryLinks[?OwnerId=='$GITHUB_OWNER' && RepositoryName=='$INFRA_REPO'].RepositoryLinkId | [0]" --output text)"
  if [[ -z "$link_id" || "$link_id" == None ]]; then
    link_id="$(aws codeconnections create-repository-link --connection-arn "$CONNECTION_ARN" \
      --owner-id "$GITHUB_OWNER" --repository-name "$INFRA_REPO" \
      --query RepositoryLinkInfo.RepositoryLinkId --output text)"
  fi

  for n in "$@"; do
    stack="$PREFIX-$n"
    file="$WORK_DIR/$INFRA_REPO/deployments/$n.deployment.yaml"

    if [[ "$(stack_status "$stack")" == NOT_FOUND ]]; then
      tpl="$(awk '/^template-file-path:/ { sub(/[ \t]+#.*$/, ""); print $2 }' "$file")"
      mapfile -t params < <(deployment_section parameters "$file")
      mapfile -t tags < <(deployment_section tags "$file")
      info "Creating $stack from $tpl (GitSync manages every update after this)"
      aws cloudformation deploy --stack-name "$stack" \
        --template-file "$WORK_DIR/$INFRA_REPO/$tpl" \
        --role-arn "$GITSYNC_ROLE_ARN" \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --parameter-overrides "${params[@]}" \
        --tags "${tags[@]}" >/dev/null
    fi

    if ! aws codeconnections get-sync-configuration --sync-type CFN_STACK_SYNC --resource-name "$stack" >/dev/null 2>&1; then
      aws codeconnections create-sync-configuration \
        --branch "$BRANCH" \
        --config-file "deployments/$n.deployment.yaml" \
        --repository-link-id "$link_id" \
        --resource-name "$stack" \
        --role-arn "$GITSYNC_ROLE_ARN" \
        --sync-type CFN_STACK_SYNC \
        --publish-deployment-status ENABLED \
        --trigger-resource-update-on FILE_CHANGE >/dev/null
      ok "GitSync attached to $stack"
    fi

    # A sync may still be running; wait for the stack to settle before the next one needs it.
    local status
    for _ in $(seq 1 120); do
      status="$(stack_status "$stack")"
      [[ "$status" == *_IN_PROGRESS ]] || break
      sleep 15
    done
    require_stack_ok "$stack"
  done
}

# Succeeds when the :latest image is in ECR.
image_exists() {
  aws ecr describe-images --repository-name "$PREFIX" --image-ids imageTag=latest >/dev/null 2>&1
}

# Steps 7-8: publishes the app repo and waits for GitHub Actions to push the first image.
first_image() {
  step "7. Publish app repo (GitHub Actions builds the first image)"
  publish_repo "$APP_REPO" render_app .github/workflows/build-push.yaml

  step "8. Wait for $PREFIX:latest in ECR"
  if image_exists; then
    ok "Image already in ECR"
    return
  fi

  if ! $PUSHED_NEW_COMMIT && $HAVE_TOKEN; then
    info "No new commit was pushed - triggering the workflow with workflow_dispatch"
    gh_api POST "/repos/$GITHUB_OWNER/$APP_REPO/actions/workflows/build-push.yaml/dispatches" \
      "{\"ref\":\"$BRANCH\"}" >/dev/null || warn "Dispatch failed - run the workflow from the Actions tab."
  elif ! $PUSHED_NEW_COMMIT; then
    warn "Start the first image build yourself (the foundation stack now trusts GitHub Actions):"
    info "https://github.com/$GITHUB_OWNER/$APP_REPO/actions/workflows/build-push.yaml > Run workflow > main"
  fi

  info "Watch: https://github.com/$GITHUB_OWNER/$APP_REPO/actions"
  for _ in $(seq 1 80); do
    if image_exists; then
      ok "Image pushed by GitHub Actions"
      return
    fi
    sleep 15
  done
  die "No :latest image after 20 min. Check the Actions run (OIDC role trust, test failures), then re-run."
}

# Step 10: checks service stability, ALB health, no NAT, no default route and no inline policies. Polls counts because 'aws ecs wait services-stable' breaks on CODE_DEPLOY services.
verify() {
  step "10. Verify"
  local alb vpc subnets cluster service
  alb="$(stack_out "$PREFIX-03-alb" LoadBalancerDnsName)"
  vpc="$(stack_out "$PREFIX-02-network" VpcId)"
  subnets="$(stack_out "$PREFIX-02-network" PrivateSubnetIds)"
  cluster="$(stack_out "$PREFIX-04-ecs" ClusterName)"
  service="$(stack_out "$PREFIX-04-ecs" ServiceName)"

  info "Waiting for the ECS service to be stable..."
  local counts r d p stable=false
  for _ in $(seq 1 40); do
    counts="$(aws ecs describe-services --cluster "$cluster" --services "$service" \
      --query 'services[0].[runningCount,desiredCount,pendingCount]' --output text)"
    read -r r d p <<<"$counts"
    if [[ "$d" -gt 0 && "$r" == "$d" && "$p" == 0 ]]; then
      stable=true
      break
    fi
    sleep 15
  done
  if $stable; then
    ok "ECS service $service is stable ($r/$d running)"
  else
    warn "Service not stable yet ($counts running/desired/pending) - check ECS > $cluster > $service > Events"
  fi

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
    [[ "$code" == 200 ]] && break
    sleep 10
  done
  if [[ "$code" == 200 ]]; then
    ok "http://$alb/health -> 200"
  else
    warn "http://$alb/health -> $code (targets may still be registering)"
  fi
  info "Version: $(curl -s "http://$alb/version" || echo n/a)"

  local nats routes
  nats="$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" "Name=state,Values=pending,available" \
    --query 'length(NatGateways)' --output text)"
  if [[ "$nats" == 0 ]]; then
    ok "No NAT gateway in $vpc"
  else
    warn "$nats NAT gateway(s) found in $vpc"
  fi

  routes="$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnets" \
    --query 'length(RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`][])' --output text)"
  if [[ "$routes" == 0 ]]; then
    ok "Private route tables have no 0.0.0.0/0 route"
  else
    warn "Default route found in private route tables"
  fi

  local inline=0 role
  for role in $(aws iam list-roles --query "Roles[?starts_with(RoleName, '$PREFIX')].RoleName" --output text); do
    (( inline += $(aws iam list-role-policies --role-name "$role" --query 'length(PolicyNames)' --output text) )) || true
  done
  if [[ "$inline" == 0 ]]; then
    ok "No inline IAM policies on $PREFIX-* roles"
  else
    warn "$inline inline policies found"
  fi

  local users
  users="$(aws iam list-users --query 'length(Users)' --output text)"
  info "IAM users in account: $users (GitHub uses OIDC, no access keys)"
}

# Runs the release pipeline once if it has never run.
start_pipeline() {
  [[ "$START_PIPELINE" == true ]] || return 0
  local p="$PREFIX-pipeline"
  local runs
  runs="$(aws codepipeline list-pipeline-executions --pipeline-name "$p" \
    --query 'length(pipelineExecutionSummaries)' --output text 2>/dev/null || echo 0)"
  if [[ "$runs" == 0 ]]; then
    # The first image was pushed before stack 04-ecs existed, so CI could not build the deploy bundle
    # (its taskdef.json is a copy of the latest task definition revision in ECS). Build and upload it here.
    local bucket key app="$WORK_DIR/$APP_REPO"
    bucket="$(stack_out "$PREFIX-01-foundation" BundleBucketName)"
    key="$(stack_out "$PREFIX-01-foundation" BundleObjectKey)"
    if ! aws s3api head-object --bucket "$bucket" --key "$key" >/dev/null 2>&1; then
      (cd "$app" && ./scripts/make-bundle.sh HEAD "$WORK_DIR/bundle.zip") \
        || die "Could not build the deploy bundle from $app."
      aws s3 cp "$WORK_DIR/bundle.zip" "s3://$bucket/$key" --only-show-errors \
        --metadata "commit=$(git -C "$app" rev-parse HEAD)"
      ok "Uploaded the first deploy bundle to s3://$bucket/$key"
    fi
    aws codepipeline start-pipeline-execution --name "$p" --query pipelineExecutionId --output text >/dev/null
    ok "Started first pipeline run (blue/green canary takes ~10-15 min)"
  else
    ok "Pipeline has already run"
  fi
  info "https://$REGION.console.aws.amazon.com/codesuite/codepipeline/pipelines/$p/view?region=$REGION"
}

# Prints URLs and demo commands.
summary() {
  step "Done"
  local alb
  alb="$(stack_out "$PREFIX-03-alb" LoadBalancerDnsName)"
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
  Release check: the app's GitHub Actions run stays yellow until CodeDeploy finishes, green = live for everyone
  Idle / clean:  bash cloudshell-deploy.sh teardown
EOF
}

# Full deployment, steps 1-10.
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

# Re-renders and pushes both repos only.
cmd_publish() {
  preflight
  github_login
  [[ "$(stack_status "$BOOTSTRAP_STACK")" != NOT_FOUND ]] || die "Run a full deploy first."
  CONNECTION_ARN="$(stack_out "$BOOTSTRAP_STACK" ConnectionArn)"
  discover_values

  step "Publish infra repo"
  publish_repo "$INFRA_REPO" render_infra deployments/01-foundation.deployment.yaml
  step "Publish app repo"
  publish_repo "$APP_REPO" render_app .github/workflows/build-push.yaml

  if $PUSHED_NEW_COMMIT; then
    info "GitHub Actions -> ECR -> EventBridge -> CodePipeline will release it."
  fi
}

# Prints stack statuses, the ALB URL and the last pipeline run.
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

# Deletes every object version so CloudFormation can delete the versioned artifact bucket.
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

# Deletes stacks 06 -> 01 so an idle environment costs nothing. 'deploy' rebuilds it from the repos.
# Each GitSync configuration is removed first, otherwise GitSync could act on the stack again.
cmd_teardown() {
  preflight
  warn "This deletes stacks $PREFIX-06 .. 01 in $REGION (GitHub repos are kept)."
  if [[ "${KEEP_BOOTSTRAP:-true}" == false ]]; then
    warn "KEEP_BOOTSTRAP=false: the bootstrap stack and GitHub connection are deleted too."
  fi
  confirm "Delete the environment?" || die "Cancelled."

  local n stack
  for n in 06-delivery 05-autoscaling 04-ecs 03-alb 02-network 01-foundation; do
    stack="$PREFIX-$n"
    aws codeconnections delete-sync-configuration --sync-type CFN_STACK_SYNC --resource-name "$stack" 2>/dev/null || true
    [[ "$(stack_status "$stack")" != NOT_FOUND ]] || continue
    if [[ "$n" == 06-delivery ]]; then
      empty_bucket "$(stack_out "$stack" ArtifactBucketName)"
    fi
    if [[ "$n" == 01-foundation ]]; then
      empty_bucket "$(stack_out "$stack" BundleBucketName)"
    fi
    info "Deleting $stack"
    aws cloudformation delete-stack --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --stack-name "$stack"
    ok "Deleted $stack"
  done

  if [[ "${KEEP_BOOTSTRAP:-true}" == false ]]; then
    aws cloudformation delete-stack --stack-name "$BOOTSTRAP_STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$BOOTSTRAP_STACK"
    ok "Deleted $BOOTSTRAP_STACK"
  fi
  ok "Teardown complete. ALB, endpoints and Fargate no longer bill."
}

# Parses the command and flags.
CMD="deploy"
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=true ;;
    deploy|publish|status|verify|teardown) CMD="$a" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $a (try --help)" ;;
  esac
done

# Logs everything to LOG_FILE and runs the chosen command.
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
