#!/usr/bin/env nu

source scripts/common.nu
source scripts/kubernetes.nu
source scripts/crossplane.nu
source scripts/argocd.nu

def main [] {}

def "main setup" [] {

    if (".env" | path exists) {
        open .env
            | lines
            | where { |line| (not ($line | str starts-with "export KUBECONFIG=")) and (not ($line | str starts-with "export KUBECONFIG_DOT=")) }
            | str join "\n"
            | $"($in)\n"
            | save .env --force
    }

    main create kubernetes kind

    main apply crossplane --provider none --app-config true --db-config true

    main apply argocd --apply-apps true

    kubectl create namespace a-team

    main print source

}

def "main destroy" [] {

    main destroy kubernetes kind

}
