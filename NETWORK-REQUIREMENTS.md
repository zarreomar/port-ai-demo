# Network Requirements

This project installs Crossplane packages from OCI registries.  
For setup to succeed, Kubernetes pods must be able to establish outbound TLS connections on port `443`.

## Required Egress

- From pod network CIDR (Kind default): `10.244.0.0/16`
- To:
  - `xpkg.crossplane.io:443`
  - `xpkg.upbound.io:443`
  - `ghcr.io:443` (if used by packages/images)
- DNS resolution from pods must work (CoreDNS reachable).

## Preflight Check

Run this before `./dot.nu setup`:

```bash
kubectl run egress-check --rm --restart=Never --image=curlimages/curl -- \
  sh -c 'curl -4 -Iv https://google.com || true; echo ---; curl -4 -Iv https://xpkg.crossplane.io/v2/ || true'
```

Expected:

- `google.com`: successful TLS handshake and HTTP response.
- `xpkg.crossplane.io/v2/`: TLS handshake success and usually HTTP `401 Unauthorized` (this is OK).

If you see `tls alert handshake failure`, pod egress is blocked/intercepted outside this repo's scripts.

## Known-Good Setup Sequence

```bash
source .env
./dot.nu setup
```

For environments similar to this one, use:

```bash
export XPKG_REGISTRY_PROVIDER=ghcr.io
export GHCR_USERNAME='<github-username-or-service-account>'
export GHCR_TOKEN='<github-token-with-read:packages>'
```

Then rerun:

```bash
./dot.nu setup
```

## Authentication Variables (Optional But Recommended)

If your registry requires auth, set:

```bash
export UPBOUND_ACCESS_ID='<your-access-id>'
export UPBOUND_TOKEN='<your-token>'
```

The setup creates pull secrets in `crossplane-system` and attaches them to package specs.

If DNS for `ghcr.io` is also rewritten in your environment, you can pin IPs for Crossplane host aliases:

```bash
export GHCR_IO_IPS='140.82.114.34,140.82.112.33'
export PKG_CONTAINERS_GITHUB_IO_IPS='185.199.108.154,185.199.109.154'
```

Values above are examples; use IPs that work in your environment.

If GHCR token requests are denied in your environment, set GHCR credentials too:

```bash
export GHCR_USERNAME='<github-username-or-service-account>'
export GHCR_TOKEN='<github-token-with-read:packages>'
```

## Proxy Variables (Only If Your Environment Uses a Proxy)

If your organization requires an outbound proxy, set:

```bash
export HTTP_PROXY='http://<proxy-host>:<port>'
export HTTPS_PROXY='http://<proxy-host>:<port>'
export NO_PROXY='127.0.0.1,localhost,.svc,.cluster.local'
```

`scripts/crossplane.nu` applies these vars to `deployment/crossplane` automatically.

## Argo CD Password Hashing Note

`scripts/argocd.nu` prefers `htpasswd` for bcrypt hashing.
If unavailable, it tries OpenSSL bcrypt. If neither works, setup continues and Argo CD uses `argocd-initial-admin-secret`.
