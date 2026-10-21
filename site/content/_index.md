---
title: muskeg.dev
tagline: online CV, demo, portfolio and other collections

platform: |
  Back in 2020, this site was a Django app pushed by a Jenkins pipeline to a two-node k3s cluster behind a hand-rolled NGINX edge proxy. It served me well, and it taught me a lot. Six years later, the job has become building platforms for other developers, so the site got the same treatment.

  Today it runs on a small Kubernetes cluster at home, and **nothing gets deployed by hand**. Git is the only source of truth: a commit is the deployment, and the cluster pulls its own state.

then_now:
  - [App, Django, Hugo static site on unprivileged NGINX]
  - [CI, Jenkins declarative pipeline, GitHub Actions]
  - [Registry, Private Docker registry, GitHub Container Registry]
  - [Deploy, Jenkins pushes to the cluster, Argo CD pulls from Git (GitOps)]
  - [Cluster, 2-node k3s provisioned with Ansible, "3-node Talos Linux on Proxmox (immutable, no SSH)"]
  - [Edge, Self-hosted public NGINX proxy, Cloudflare Tunnel (no inbound ports)]
  - [TLS, certbot + Let's Encrypt, "cert-manager: Let's Encrypt wildcard via DNS-01"]
  - [Secrets, git-secrets, External Secrets + 1Password]
  - [Updates, GitHub push webhook triggers Jenkins, "Renovate opens PRs, Argo CD syncs on merge"]

muskeg: |
  The muskeg is where I grew up. It's a type of terrain created by the accumulation of water and sediments on the near-surface bedrock preventing drainage. This type of terrain can be found all over Abitibi, my home region. I always loved the imagery of that rough terrain, hard to navigate when you're not used to it. A terrain hiding depth and complexity under a seemingly calm and uneventful surface.

about: |
  I've been in IT for the best part of my life, and for over 20 years professionally. I started in data storage and recovery: electronics work on failed hard drives, building ZFS arrays, archiving 15 years of multimedia projects on LTO tapes. Then came Linux systems administration in the VFX and immersive entertainment worlds, at Moment Factory and Framestore.

  Today I lead a DevOps platform team in Montreal, focused on GitOps, CI/CD, Kubernetes and developer enablement. Still an automation evangelist at heart, with solid roots in infrastructure, storage and networking. The longer version is on [LinkedIn](https://www.linkedin.com/in/rlanouette).

  I speak French and English, get by in Japanese at work, and know just enough Spanish to order food.
---
