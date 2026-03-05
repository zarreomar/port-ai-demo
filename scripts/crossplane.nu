#!/usr/bin/env nu

def "get xpkg registry provider" [] {
    if XPKG_REGISTRY_PROVIDER in $env {
        $env.XPKG_REGISTRY_PROVIDER
    } else if XPKG_REGISTRY in $env {
        $env.XPKG_REGISTRY
    } else {
        "xpkg.crossplane.io"
    }
}

def "get xpkg registry dot" [] {
    if XPKG_REGISTRY_DOT in $env {
        $env.XPKG_REGISTRY_DOT
    } else if XPKG_REGISTRY in $env {
        $env.XPKG_REGISTRY
    } else {
        "xpkg.upbound.io"
    }
}

def "xpkg package" [
    registry: string,
    repository: string,
    version: string
] {
    $"($registry)/($repository):($version)"
}

def "with package pull secrets" [
    spec: record,
    package_pull_secrets: list
] {
    if ($package_pull_secrets | is-empty) {
        $spec
    } else {
        $spec | merge { packagePullSecrets: $package_pull_secrets }
    }
}

def "get env or dot-env" [
    name: string
] {
    if $name in $env {
        ($env | get $name)
    } else if (".env" | path exists) {
        let line = (
            open .env
                | lines
                | where { |l| $l | str starts-with $"export ($name)=" }
                | get -o 0
                | default ""
        )
        if ($line | is-not-empty) {
            $line
                | str replace $"export ($name)=" ""
                | str trim --char '"'
                | str trim --char "'"
        } else {
            ""
        }
    } else {
        ""
    }
}

def "setup package pull secrets" [] {
    mut package_pull_secrets = []
    let access_id = (get env or dot-env "UPBOUND_ACCESS_ID")
    let token = (get env or dot-env "UPBOUND_TOKEN")
    let ghcr_username = (get env or dot-env "GHCR_USERNAME")
    let ghcr_token = (get env or dot-env "GHCR_TOKEN")

    if ($access_id | is-not-empty) and ($token | is-not-empty) {

        print $"\n(ansi green_bold)Configuring registry credentials for package pulls...(ansi reset)\n"

        (
            kubectl --namespace crossplane-system
                create secret docker-registry xpkg-upbound-creds
                --docker-server xpkg.upbound.io
                --docker-username $access_id
                --docker-password $token
                --dry-run=client --output yaml
        ) | kubectl apply --filename -

        (
            kubectl --namespace crossplane-system
                create secret docker-registry xpkg-crossplane-creds
                --docker-server xpkg.crossplane.io
                --docker-username $access_id
                --docker-password $token
                --dry-run=client --output yaml
        ) | kubectl apply --filename -

        $package_pull_secrets = [
            { name: "xpkg-upbound-creds" }
            { name: "xpkg-crossplane-creds" }
        ]

    } else {

        print $"(ansi yellow_bold)UPBOUND_ACCESS_ID and/or UPBOUND_TOKEN are not set. Continuing without package pull secrets.(ansi reset)"

    }

    if ($ghcr_username | is-not-empty) and ($ghcr_token | is-not-empty) {

        print $"\n(ansi green_bold)Configuring GHCR credentials for package pulls...(ansi reset)\n"

        (
            kubectl --namespace crossplane-system
                create secret docker-registry ghcr-creds
                --docker-server ghcr.io
                --docker-username $ghcr_username
                --docker-password $ghcr_token
                --dry-run=client --output yaml
        ) | kubectl apply --filename -

        $package_pull_secrets = ($package_pull_secrets | append { name: "ghcr-creds" })

    } else {

        print $"(ansi yellow_bold)GHCR_USERNAME and/or GHCR_TOKEN are not set. Continuing without GHCR pull secret.(ansi reset)"

    }

    $package_pull_secrets
}

def "setup crossplane proxy" [] {
    let http_proxy = (get env or dot-env "HTTP_PROXY")
    let https_proxy = (get env or dot-env "HTTPS_PROXY")
    let no_proxy = (get env or dot-env "NO_PROXY")

    if ($http_proxy | is-empty) and ($https_proxy | is-empty) and ($no_proxy | is-empty) {
        return
    }

    print $"\n(ansi green_bold)Configuring proxy env vars on Crossplane deployment...(ansi reset)\n"

    if ($http_proxy | is-not-empty) {
        (
            kubectl --namespace crossplane-system set env
                deployment/crossplane $"HTTP_PROXY=($http_proxy)"
        )
    }

    if ($https_proxy | is-not-empty) {
        (
            kubectl --namespace crossplane-system set env
                deployment/crossplane $"HTTPS_PROXY=($https_proxy)"
        )
    }

    if ($no_proxy | is-not-empty) {
        (
            kubectl --namespace crossplane-system set env
                deployment/crossplane $"NO_PROXY=($no_proxy)"
        )
    }

    (
        kubectl --namespace crossplane-system
            rollout status deployment/crossplane --timeout 5m
    )
}

def "setup crossplane host aliases" [
    --xpkg-ips = ["3.67.33.93" "3.77.103.135"]
] {
    print $"\n(ansi green_bold)Configuring hostAliases for Crossplane package registries...(ansi reset)\n"

    let resolve_ipv4 = {|hostname: string|
        (
            do --ignore-errors {
                ^getent ahostsv4 $hostname
                    | lines
                    | parse "{ip} {rest}"
                    | get ip
                    | uniq
                    | first 2
            } | default []
        )
    }

    let ghcr_ips_raw = (get env or dot-env "GHCR_IO_IPS")
    let ghcr_ips = (
        if ($ghcr_ips_raw | is-empty) {
            (do $resolve_ipv4 "ghcr.io")
        } else {
            $ghcr_ips_raw
                | split row ","
                | each {|ip| $ip | str trim}
                | where {|ip| $ip != ""}
        }
    )
    let pkg_containers_ips_raw = (get env or dot-env "PKG_CONTAINERS_GITHUB_IO_IPS")
    let pkg_containers_ips = (
        if ($pkg_containers_ips_raw | is-empty) {
            (do $resolve_ipv4 "pkg-containers.githubusercontent.com")
        } else {
            $pkg_containers_ips_raw
                | split row ","
                | each {|ip| $ip | str trim}
                | where {|ip| $ip != ""}
        }
    )

    mut host_aliases = [{
        ip: ($xpkg_ips | get 0)
        hostnames: ["xpkg.crossplane.io" "gateway.scarf.sh"]
    } {
        ip: ($xpkg_ips | get 1)
        hostnames: ["xpkg.crossplane.io" "gateway.scarf.sh"]
    }]

    for ip in $ghcr_ips {
        $host_aliases = ($host_aliases | append {
            ip: $ip
            hostnames: ["ghcr.io"]
        })
    }

    for ip in $pkg_containers_ips {
        $host_aliases = ($host_aliases | append {
            ip: $ip
            hostnames: ["pkg-containers.githubusercontent.com"]
        })
    }

    let patch = ({
        spec: {
            template: {
                spec: {
                    hostAliases: $host_aliases
                }
            }
        }
    } | to json)

    (
        kubectl --namespace crossplane-system
            patch deployment crossplane --type merge --patch $patch
    )

    (
        kubectl --namespace crossplane-system
            rollout status deployment/crossplane --timeout 5m
    )
}

# Installs and configures Crossplane with optional cloud provider setup
#
# Examples:
# > main apply crossplane --provider aws
# > main apply crossplane --provider google --app
# > main apply crossplane --provider azure --db-config --github-config --github-user user --github-token token
def --env "main apply crossplane" [
    --provider = none,       # Which provider to use. Available options are `none`, `google`, `aws`, and `azure`
    --app-config = false,    # Whether to apply DOT App Configuration
    --db-config = false,     # Whether to apply DOT SQL Configuration
    --github-config = false, # Whether to apply DOT GitHub Configuration
    --github-user: string,   # GitHub user required for the DOT GitHub Configuration and optinal for the DOT App Configuration
    --github-token: string,  # GitHub token required for the DOT GitHub Configuration and optinal for the DOT App Configuration
    --policies = false,      # Whether to create Validating Admission Policies
    --skip-login = false,    # Whether to skip the login (only for Azure)
    --db-provider = false    # Whether to apply database provider (not needed if --db-config is `true`)
] {

    print $"\nInstalling (ansi green_bold)Crossplane(ansi reset)...\n"
    let provider_registry = get xpkg registry provider
    let dot_registry = get xpkg registry dot

    helm repo add crossplane https://charts.crossplane.io/stable

    helm repo update

    (
        helm upgrade --install crossplane "crossplane/crossplane"
            --namespace crossplane-system --create-namespace
            --set provider.defaultActivations={"*.m.upbound.io","*.m.crossplane.io"}
            --wait
    )
    setup crossplane proxy
    setup crossplane host aliases
    let package_pull_secrets = (setup package pull secrets)

    mut provider_data = {}
    if $provider == "google" {
        $provider_data = setup google
    } else if $provider == "aws" {
        setup aws
    } else if $provider == "azure" {
        setup azure --skip-login $skip_login
    }

    if $app_config {

        print $"\n(ansi green_bold)Applying `dot-application` Configuration...(ansi reset)\n"

        let version = "v3.0.46"
        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Configuration"
            metadata: { name: "crossplane-app" }
            spec: (with package pull secrets {
                package: (xpkg package $dot_registry "devops-toolkit/dot-application" $version)
            } $package_pull_secrets)
        } | to yaml | kubectl apply --filename -

        if $policies {

            {
                apiVersion: "admissionregistration.k8s.io/v1"
                kind: "ValidatingAdmissionPolicy"
                metadata: { name: "dot-app" }
                spec: {
                    failurePolicy: "Fail"
                    matchConstraints: {
                        resourceRules: [{
                            apiGroups:   ["devopstoolkit.live"]
                            apiVersions: ["*"]
                            operations:  ["CREATE", "UPDATE"]
                            resources:   ["appclaims"]
                        }]
                    }
                    validations: [
                        {
                            expression: "has(object.spec.parameters.scaling) && has(object.spec.parameters.scaling.enabled) && object.spec.parameters.scaling.enabled"
                            message: "`spec.parameters.scaling.enabled` must be set to `true`."
                        }, {
                            expression: "has(object.spec.parameters.scaling) && object.spec.parameters.scaling.min > 1"
                            message: "`spec.parameters.scaling.min` must be greater than `1`."
                        }
                    ]
                }
            } | to yaml | kubectl apply --filename -

            {
                apiVersion: "admissionregistration.k8s.io/v1"
                kind: "ValidatingAdmissionPolicyBinding"
                metadata: { name: "dot-app" }
                spec: {
                    policyName: "dot-app"
                    validationActions: ["Deny"]
                }
            } | to yaml | kubectl apply --filename -

        }

    }

    if ($db_config or $db_provider) and $provider == "google" {

        start $"https://console.cloud.google.com/marketplace/product/google/sqladmin.googleapis.com?project=($provider_data.project_id)"

        print $"\n(ansi yellow_bold)ENABLE(ansi reset) the API.\nPress the (ansi yellow_bold)enter key(ansi reset) to continue.\n"
        input

    }

    if $db_config {

        print $"\n(ansi green_bold)Applying `dot-sql` Configuration...(ansi reset)\n"

        let version = "v2.2.11"
        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Configuration"
            metadata: { name: "crossplane-sql" }
            spec: (with package pull secrets {
                package: (xpkg package $dot_registry "devops-toolkit/dot-sql" $version)
            } $package_pull_secrets)
        } | to yaml | kubectl apply --filename -

    } else if $db_provider {

        apply db-provider $provider --package-pull-secrets $package_pull_secrets

    }

    if $github_config {

        print $"\n(ansi green_bold)Applying `dot-github` Configuration...(ansi reset)\n"

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Configuration"
            metadata: { name: "devops-toolkit-dot-github" }
            spec: (with package pull secrets {
                package: (xpkg package $dot_registry "devops-toolkit/dot-github" "v0.0.57")
            } $package_pull_secrets)
        } | to yaml | kubectl apply --filename -

    }

    if $db_config or $github_config or $app_config {

        print $"\n(ansi green_bold)Applying Kubernetes and Helm providers...(ansi reset)\n"

        {
            apiVersion: "rbac.authorization.k8s.io/v1"
            kind: "ClusterRole"
            metadata: {
                name: "crossplane-all"
                labels: {
                    "rbac.crossplane.io/aggregate-to-crossplane": "true"
                }
            }
            rules: [{
                apiGroups: ["*"]
                resources: ["*"]
                verbs: ["*"]
            }]
        } | to yaml | kubectl apply --filename -


        {
            apiVersion: "v1"
            kind: "ServiceAccount"
            metadata: {
                name: "crossplane-provider-helm"
                namespace: "crossplane-system"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "rbac.authorization.k8s.io/v1"
            kind: "ClusterRoleBinding"
            metadata: {  name: crossplane-provider-helm }
            subjects: [{
                kind: "ServiceAccount"
                name: "crossplane-provider-helm"
                namespace: "crossplane-system"
            }]
            roleRef: {
                kind: "ClusterRole"
                name: "cluster-admin"
                apiGroup: "rbac.authorization.k8s.io"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1beta1"
            kind: "DeploymentRuntimeConfig"
            metadata: { name: "crossplane-provider-helm" }
            spec: { deploymentTemplate: { spec: {
                selector: {}
                template: { spec: {
                    containers: [{ name: "package-runtime" }]
                    serviceAccountName: "crossplane-provider-helm"
                } }
            } } }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "crossplane-provider-helm" }
            spec: (with package pull secrets {
                package: (xpkg package $provider_registry "crossplane-contrib/provider-helm" "v1.0.0")
                runtimeConfigRef: { name: "crossplane-provider-helm" }
            } $package_pull_secrets)
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "v1"
            kind: "ServiceAccount"
            metadata: {
                name: "crossplane-provider-kubernetes"
                namespace: "crossplane-system"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "rbac.authorization.k8s.io/v1"
            kind: "ClusterRoleBinding"
            metadata: { name: "crossplane-provider-kubernetes" }
            subjects: [{
                kind: "ServiceAccount"
                name: "crossplane-provider-kubernetes"
                namespace: "crossplane-system"
            }]
            roleRef: {
                kind: "ClusterRole"
                name: "cluster-admin"
                apiGroup: "rbac.authorization.k8s.io"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1beta1"
            kind: "DeploymentRuntimeConfig"
            metadata: { name: "crossplane-provider-kubernetes" }
            spec: { deploymentTemplate: { spec: {
                selector: {}
                template: { spec: {
                    containers: [{ name: "package-runtime" }]
                    serviceAccountName: "crossplane-provider-kubernetes"
                } }
            } } }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "crossplane-provider-kubernetes" }
            spec: (with package pull secrets {
                package: (xpkg package $provider_registry "crossplane-contrib/provider-kubernetes" "v1.0.0")
                runtimeConfigRef: { name: "crossplane-provider-kubernetes" }
            } $package_pull_secrets)
        } | to yaml | kubectl apply --filename -

    }

    if $db_config or $app_config or $github_config or $db_provider {
        wait crossplane
    }

    if ($db_config and $provider != "none") or $db_provider {

        if $provider == "google" {
            (
                apply providerconfig $provider
                    --google-project-id $provider_data.project_id
            )
        } else {
            apply providerconfig $provider
        }


    }

    if ($github_user | is-not-empty) and ($github_token | is-not-empty) {

        {
            apiVersion: v1,
            kind: Secret,
            metadata: {
                name: github,
                namespace: crossplane-system
            },
            type: Opaque,
            stringData: {
                credentials: $"{\"token\":\"($github_token)\",\"owner\":\"($github_user)\"}"
            }
        } | to yaml | kubectl apply --filename -

        if $app_config or $github_config {

            {
                apiVersion: "github.upbound.io/v1beta1",
                kind: ProviderConfig,
                metadata: {
                    name: default
                },
                spec: {
                    credentials: {
                        secretRef: {
                            key: credentials,
                            name: github,
                            namespace: crossplane-system,
                        },
                        source: Secret
                    }
                }
            } | to yaml | kubectl apply --filename -

        }

    }

}

# Deletes Crossplane resources and waits for managed resources to be cleaned up
#
# Examples:
# > main delete crossplane
# > main delete crossplane --kind AppClaim --name myapp --namespace default
def "main delete crossplane" [
    --kind: string,
    --name: string,
    --namespace: string
] {

    if ($kind | is-not-empty) and ($name | is-not-empty) and ($namespace | is-not-empty) {
        kubectl --namespace $namespace delete $kind $name
    }

    print $"\nWaiting for (ansi green_bold)Crossplane managed resources(ansi reset) to be deleted...\n"

    mut command = { kubectl get managed --output name }
    if ($name | is-not-empty) {
        $command = {
            (
                kubectl get managed --output name
                    --selector $"crossplane.io/claim-name=($name)"
            )
        }
    }

    mut resources = (do $command)
    mut counter = ($resources | wc -l | into int)

    while $counter > 0 {
        print $"($resources)\nWaiting for remaining (ansi green_bold)($counter)(ansi reset) managed resources to be (ansi green_bold)removed(ansi reset)...\n"
        sleep 10sec
        $resources = (do $command)
        $counter = ($resources | wc -l | into int)
    }

}

def "main publish crossplane" [
    package: string
    --sources = ["compositions"]
    --version = ""
] {
    let dot_registry = get xpkg registry dot

    mut version = $version
    if $version == "" {
        $version = $env.VERSION
    }

    package generate --sources $sources

    up login --token $env.UP_TOKEN

    up xpkg build --package-root package --output $"($package).xpkg"

    (
        up xpkg push
            (xpkg package $dot_registry $"($env.UP_ACCOUNT)/dot-($package)" $version)
    )

    rm --force $"package/($package).xpkg"

    open config.yaml
        | upsert spec.package (xpkg package $dot_registry $"devops-toolkit/dot-($package)" $version)
        | save config.yaml --force

}

def "package generate" [
    --sources = ["compositions"]
] {

    for source in $sources {
        kcl run $"kcl/($source).k" |
            save $"package/($source).yaml" --force
    }

}

def "apply providerconfig" [
    provider: string,
    --google-project-id: string,
] {

    if $provider == "google" {

        {
            apiVersion: "gcp.m.upbound.io/v1beta1"
            kind: "ClusterProviderConfig"
            metadata: { name: "default" }
            spec: {
                projectID: $google_project_id
                credentials: {
                    source: "Secret"
                    secretRef: {
                        namespace: "crossplane-system"
                        name: "gcp-creds"
                        key: "creds"
                    }
                }
            }
        } | to yaml | kubectl apply --filename -

    } else if $provider == "aws" {

        {
            apiVersion: "aws.m.upbound.io/v1beta1"
            kind: "ClusterProviderConfig"
            metadata: { name: default }
            spec: {
                credentials: {
                    source: Secret
                    secretRef: {
                        namespace: crossplane-system
                        name: aws-creds
                        key: creds
                    }
                }
            }
        } | to yaml | kubectl apply --filename -

    } else if $provider == "azure" {

        {
            apiVersion: "azure.m.upbound.io/v1beta1"
            kind: "ClusterProviderConfig"
            metadata: { name: default }
            spec: {
                credentials: {
                    source: "Secret"
                    secretRef: {
                        namespace: "crossplane-system"
                        name: "azure-creds"
                        key: "creds"
                    }
                }
            }
        } | to yaml | kubectl apply --filename -

    }

}

def "apply db-provider" [
    provider: string
    --package-pull-secrets = []
] {
    let provider_registry = get xpkg registry provider

    if $provider == "google" {

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "provider-gcp-sql" }
            spec: (with package pull secrets {
                package: (xpkg package $provider_registry "crossplane-contrib/provider-gcp-sql" "v1.14.0")
            } $package_pull_secrets)
        } | to yaml | kubectl apply --filename -

    } else if $provider == "aws" {

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "provider-aws-rds" }
            spec: (with package pull secrets {
                package: (xpkg package $provider_registry "crossplane-contrib/provider-aws-rds" "v1.23.0")
            } $package_pull_secrets)
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "provider-aws-ec2" }
            spec: (with package pull secrets {
                package: (xpkg package $provider_registry "crossplane-contrib/provider-aws-ec2" "v1.23.0")
            } $package_pull_secrets)
        } | to yaml | kubectl apply --filename -

    } else if $provider == "azure" {

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "provider-azure-dbforpostgresql" }
            spec: (with package pull secrets {
                package: (xpkg package $provider_registry "crossplane-contrib/provider-azure-dbforpostgresql" "v1.13.0")
            } $package_pull_secrets)
        } | to yaml | kubectl apply --filename -

    }
}


# Waits for all Crossplane providers to be deployed and healthy
def "wait crossplane" [] {

    print $"\n(ansi green_bold)Waiting for Crossplane providers to be deployed...(ansi reset)\n"

    let timeout = 30min
    let interval = 10sec
    let deadline = ((date now) + $timeout)

    loop {

        let provider_data = (
            do --ignore-errors {
                kubectl get provider.pkg.crossplane.io --output json
                    | from json
            }
        )
        let items = ($provider_data | get -o items | default [])

        if ($items | is-empty) {
            print "No providers found yet. Waiting..."
            sleep $interval
            if (date now) > $deadline {
                error make {msg: "Timed out waiting for providers to be created."}
            }
            continue
        }

        let status = (
            $items
                | each {|item|
                    let conditions = ($item | get -o status.conditions | default [])
                    let installed = (
                        $conditions
                            | where type == "Installed"
                            | get -o 0.status
                            | default "Unknown"
                    )
                    let healthy = (
                        $conditions
                            | where type == "Healthy"
                            | get -o 0.status
                            | default "Unknown"
                    )
                    let reason = (
                        $conditions
                            | where type == "Healthy"
                            | get -o 0.reason
                            | default ""
                    )
                    {
                        name: ($item | get metadata.name)
                        installed: $installed
                        healthy: $healthy
                        reason: $reason
                    }
                }
        )

        let not_ready = ($status | where healthy != "True")
        if ($not_ready | is-empty) {
            print $"\n(ansi green_bold)All Crossplane providers are healthy.(ansi reset)\n"
            break
        }

        let tls_errors = (
            $not_ready
                | where { |row| ($row.reason | str downcase | str contains "tls") }
        )
        if ($tls_errors | is-not-empty) {
            error make {
                msg: "Provider package pull failed with TLS handshake error. Check registry connectivity and package registry host."
            }
        }

        print $"\nWaiting for provider health. Remaining: (($not_ready | length))\n"
        $not_ready | table

        sleep $interval

        if (date now) > $deadline {
            error make {
                msg: $"Timed out waiting for providers to be healthy. Remaining providers: ((
                    $not_ready
                        | get name
                        | str join ', '
                ))"
            }
        }
    }

}

def "setup google" [] {

    mut project_id = ""

    print $"\nInstalling (ansi green_bold)Crossplane Google Cloud Provider(ansi reset)...\n"

    if PROJECT_ID in $env {
        $project_id = $env.PROJECT_ID
    } else {

        gcloud auth login

        $project_id = $"dot-(date now | format date "%Y%m%d%H%M%S")"
        $env.PROJECT_ID = $project_id
        $"export PROJECT_ID=($project_id)\n" | save --append .env

        gcloud projects create $project_id

        start $"https://console.cloud.google.com/billing/enable?project=($project_id)"

        print $"
Select the (ansi yellow_bold)Billing account(ansi reset) and press the (ansi yellow_bold)SET ACCOUNT(ansi reset) button.
Press the (ansi yellow_bold)enter key(ansi reset) to continue.
"
        input

    }

    let sa_name = "devops-toolkit"

    let sa = $"($sa_name)@($project_id).iam.gserviceaccount.com"

    let project = $project_id

    do --ignore-errors {(
        gcloud iam service-accounts create $sa_name
            --project $project
    )}

    sleep 5sec

    (
        gcloud projects add-iam-policy-binding
            --role roles/admin $project
            --member $"serviceAccount:($sa)"
    )

    (
        gcloud iam service-accounts keys
            create gcp-creds.json --project $project
            --iam-account $sa
    )

    (
        kubectl --namespace crossplane-system
            create secret generic gcp-creds
            --from-file creds=./gcp-creds.json
    )

    { project_id: $project }

}

def "setup aws" [] {

    print $"\nInstalling (ansi green_bold)Crossplane AWS Provider(ansi reset)...\n"

    if AWS_ACCESS_KEY_ID not-in $env {
        $env.AWS_ACCESS_KEY_ID = input $"(ansi yellow_bold)Enter AWS Access Key ID: (ansi reset)"
    }
    $"export AWS_ACCESS_KEY_ID=($env.AWS_ACCESS_KEY_ID)\n"
        | save --append .env

    if AWS_SECRET_ACCESS_KEY not-in $env {
        $env.AWS_SECRET_ACCESS_KEY = input $"(ansi yellow_bold)Enter AWS Secret Access Key: (ansi reset)"
    }
    $"export AWS_SECRET_ACCESS_KEY=($env.AWS_SECRET_ACCESS_KEY)\n"
        | save --append .env

    $"[default]
aws_access_key_id = ($env.AWS_ACCESS_KEY_ID)
aws_secret_access_key = ($env.AWS_SECRET_ACCESS_KEY)
" | save aws-creds.conf --force

    (
        kubectl --namespace crossplane-system
            create secret generic aws-creds
            --from-file creds=./aws-creds.conf
            --from-literal $"accessKeyID=($env.AWS_ACCESS_KEY_ID)"
            --from-literal $"secretAccessKey=($env.AWS_SECRET_ACCESS_KEY)"
    )

}

def "setup azure" [
    --skip-login = false
] {

    print $"\nInstalling (ansi green_bold)Crossplane Azure Provider(ansi reset)...\n"

    mut azure_tenant = ""
    if AZURE_TENANT not-in $env {
        $azure_tenant = input $"(ansi yellow_bold)Enter Azure Tenant: (ansi reset)"
    } else {
        $azure_tenant = $env.AZURE_TENANT
    }
    $"export AZURE_TENANT=($azure_tenant)\n" | save --append .env

    if $skip_login == false { az login --tenant $azure_tenant }

    let subscription_id = (az account show --query id -o tsv)

    (
        az ad sp create-for-rbac --sdk-auth --role Owner
            --scopes $"/subscriptions/($subscription_id)"
            | save azure-creds.json --force
    )

    (
        kubectl --namespace crossplane-system
            create secret generic azure-creds
            --from-file creds=./azure-creds.json
    )

}
