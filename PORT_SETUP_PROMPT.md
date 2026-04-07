I need help continuing Port.io setup for my k3s cluster (port-ai-demo project).

## What's Done:
1. **K8s Exporter**: Deployed via ArgoCD at `apps/port-k8s-exporter/`. Syncing namespaces, workloads, services, ingress, pods to Port blueprints.
2. **GitHub Integration**: Connected - syncing workflows from `zarreomar/port-ai-demo` (Manage Crossplane App, Manage SQL Database workflows).
3. **Existing Blueprints**: k8s_namespace, k8s_workload, workload, service, ingress, k8s_pod, githubWorkflow, githubWorkflowRun, githubRepository, crossplaneApp, crossplaneSql

## What Needs to Be Done:
**Part 3: Create Self-Service Actions in Port UI**

Go to **Builder → Actions** and create these 6 actions:

1. **Create App** (crossplaneApp)
   - Trigger: GitHub → Workflow `Manage Crossplane App` (254574071)
   - Inputs: name, namespace (default: a-team), image, tag (default: latest), port (default: 8080), host, scaling_min (default: 1), scaling_max (default: 3)

2. **Update App** (crossplaneApp)
   - Same workflow, but add input: action = "update"

3. **Delete App** (crossplaneApp)
   - Same workflow, but add input: action = "delete"

4. **Create SQL** (crossplaneSql)
   - Trigger: GitHub → Workflow `Manage SQL Database` (254574072)
   - Inputs: name, namespace (default: a-team), version (default: 13), size (default: small), region (default: us-east-1), provider (default: google)

5. **Update SQL** (crossplaneSql)
   - Same workflow, but add input: action = "update"

6. **Delete SQL** (crossplaneSql)
   - Same workflow, but add input: action = "delete"

For all actions, use `{{ .run.id }}` for the `port_run_id` parameter.

Help me create each action step by step.
