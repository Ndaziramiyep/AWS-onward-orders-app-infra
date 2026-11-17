# AWS_LAB_03B

Onward Logistics: delivering order system updates safely (ECS Fargate, CloudFormation GitSync, GitHub Actions OIDC, CodePipeline, CodeDeploy blue/green).

| Folder | Published as |
|---|---|
| `onward-orders-infra/` | GitHub repo `onward-orders-infra` (CloudFormation + GitSync) |
| `onward-orders-app/` | GitHub repo `onward-orders-app` (Flask app, Dockerfile, CI, appspec, taskdef) |

## Deploy everything from AWS CloudShell

```bash
git clone https://github.com/Ndaziramiyep/AWS_LAB_03B.git && cd AWS_LAB_03B
export GITHUB_TOKEN=<classic PAT with scopes: repo, workflow>   # or you are prompted
bash cloudshell-deploy.sh
```

The script creates and publishes the two lab repos and deploys the `00-bootstrap` stack. It then waits for the one-time GitHub connection authorization, which is the only console step. Next it runs GitSync for stacks 01 to 03, waits for GitHub Actions to push the first image, and runs GitSync for stacks 04 to 06. Finally it verifies the environment (ALB health, no NAT, no default route in private subnets, no inline policies). Every step is idempotent, so if CloudShell times out, run it again.

| Command | Purpose |
|---|---|
| `bash cloudshell-deploy.sh status` | Stack status, ALB URL, last pipeline run |
| `bash cloudshell-deploy.sh publish` | Push local changes in both folders to their repos (triggers a release) |
| `bash cloudshell-deploy.sh verify` | Re-run the security and HA checks |
| `bash cloudshell-deploy.sh teardown` | Delete stacks 06 to 01 so an idle environment costs nothing |

Settings such as `AWS_REGION`, `PREFIX`, `REPO_VISIBILITY` and `CONNECTION_ARN` are listed at the top of [cloudshell-deploy.sh](cloudshell-deploy.sh).
