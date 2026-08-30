# Introduction

Infrastructure-as-Code documentation for ZanyHunter's homelab — a Talos Kubernetes cluster on Proxmox, managed with OpenTofu and Terragrunt, with app deployment handled by ArgoCD GitOps. This site follows the [Diátaxis](https://diataxis.fr/) documentation framework, split into four sections:

- **[Guides](./guides/deploy-from-scratch.md)** — task-oriented instructions for something you already know you want to do: standing up the environment from scratch, onboarding a new app, restoring a backup, and so on.
- **[Tutorials](./tutorials/README.md)** — teach-by-doing lessons for someone new to this repo. Currently a stub; see its index page for why.
- **[Reference](./reference/repository-layout.md)** — dry factual lookups: directory layouts, exact export settings, hostname tables.
- **[Explanation](./explanation/terragrunt-units.md)** — the architecture and the reasoning behind it: why things are built the way they are, including real gotchas found running this live.

If you're standing up a fresh environment, start with [Deploy From Scratch](./guides/deploy-from-scratch.md).
