

# ==========================================================

# AZURE project 
# azure-devops-acr-containerapp-bootstrap
# Azure DevOps + Azure Repos + Pipelines
# ACR + Azure Container Apps + Existing VNet

# push code → DevOps pipeline auto-triggers → builds Docker image → pushes to ACR → updates Container App


# Azure DevOps	az devops
# Azure Repos	az repos
# Azure Pipelines	az pipelines
# Azure Container Registry (ACR)	az acr
# Azure Container Apps	az containerapp
# Azure Container Apps Environment	az containerapp env
# Azure Resource Group	az group
# Azure Virtual Network (VNet)	az network vnet
# Azure VNet Subnet	az network vnet subnet
# Azure Service Principal (AAD)	az ad sp
# Azure DevOps Service Connection	az devops service-endpoint
# Azure CLI extensions	azure-devops, containerapp


#./azure-mvp.sh CREATE
#./azure-mvp.sh DEPLOY
#./azure-mvp.sh STATUS
#./azure-mvp.sh UPDATE "version 2"
#./azure-mvp.sh COST
#./azure-mvp.sh DESTROY

# az containerapp show -g "rg-11111111111" -n "app-p20261020" --query "{name:name,url:properties.configuration.ingress.fqdn}"   -o table
# https://app-11111111.<random>.uksouth.azurecontainerapps.io

# FinOps Stock Keeping Unit
# Basic SKU Cost:  ACR Basic ~$5/mo  Container Apps Consumption ~$0 idle  <$0.01 for 1h test

# ACR SKU: Basic
# Container Apps: Consumption actual cost depends on usage.

# ==========================================================



#!/usr/bin/env bash
set -Eeuo pipefail


devopsorgurl="https://dev.azure.com/<organization>"

devopsprojectname=""


reponame=""
pipelinename=""

azurelocation="uksouth"

vnetname=""
vnetrg=""
subnetname="subnetnet-containerapps"
subnetcidr="172.16.1.0/27"

rgname=""
acrname=""


appname=""
envname=""

serviceconnectionname="sc-mvp"

basedockerimage="httpd:2.4.69-alpine"

statefilepath="$HOME/.mvp.env"
workdirpath="$HOME/mvp-work"

timerstartepoch=0

pipelineid=""
spclientid=""

##################

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

timer_start() {
    timerstartepoch=$(date +%s)
    log "Operation started"
}

timer_end() {
    local elapsedseconds
    elapsedseconds=$(($(date +%s) - timerstartepoch))
    printf '\nElapsed time: %02d:%02d:%02d (HH:MM:SS)\n' \
        $((elapsedseconds / 3600)) \
        $(((elapsedseconds % 3600) / 60)) \
        $((elapsedseconds % 60))
}

on_error() {
    local exitstatuscode=$?
    echo "Operation failed: exit $exitstatuscode"
    (( timerstartepoch > 0 )) && timer_end
    exit "$exitstatuscode"
}

trap on_error ERR

require_tools() {
    for requiredtool in az git jq python3; do
        command -v "$requiredtool" >/dev/null ||
            die "Missing command: $requiredtool"
    done

    az account show >/dev/null ||
        die "Run az login"

    az extension add --name azure-devops --upgrade --only-show-errors
    az extension add --name containerapp --upgrade --only-show-errors
}

devops_login() {
    read -rsp "Azure DevOps PAT: " personalaccesstoken
    echo
    [[ -n "$personalaccesstoken" ]] || die "PAT is empty"

    export AZURE_DEVOPS_EXT_PAT="$personalaccesstoken"
    basicauthheader=$(printf ':%s' "$personalaccesstoken" | base64 -w0)
    unset personalaccesstoken

    az devops configure --defaults \
        organization="$devopsorgurl" project="$devopsprojectname"

    az devops project show \
        --organization "$devopsorgurl" \
        --project "$devopsprojectname" >/dev/null ||
        die "Project not found"
}

git_cmd() {
    git -c "http.extraheader=AUTHORIZATION: Basic $basicauthheader" "$@"
}

save_state() {
    umask 077
    cat > "$statefilepath" <<EOF
devopsorgurl='$devopsorgurl'
devopsprojectname='$devopsprojectname'
reponame='$reponame'
rgname='$rgname'
acrname='$acrname'
appname='$appname'
envname='$envname'
azurelocation='$azurelocation'
vnetname='$vnetname'
vnetrg='$vnetrg'
subnetname='$subnetname'
isrgowned='$isrgowned'
issubnetowned='$issubnetowned'
spclientid='$spclientid'
pipelineid='$pipelineid'
EOF
    chmod 600 "$statefilepath"
}

load_state() {
    [[ -f "$statefilepath" ]] || die "State file missing"
    source "$statefilepath"
}

check_project() {
    az devops project show \
        --organization "$devopsorgurl" \
        --project "$devopsprojectname" \
        --query "{name:name,id:id,state:state}" -o table
}

network_check() {
    local vnetregion existingsubnetname subnetaddressprefix subnetsjson

    vnetregion=$(az network vnet show \
        -g "$vnetrg" -n "$vnetname" \
        --query location -o tsv)

    [[ "$vnetregion" == "$azurelocation" ]] ||
        die "VNet region mismatch: $vnetregion"

    existingsubnetname=$(az network vnet subnet show \
        -g "$vnetrg" --vnet-name "$vnetname" \
        -n "$subnetname" --query name -o tsv 2>/dev/null || true)

    if [[ -n "$existingsubnetname" ]]; then
        subnetaddressprefix=$(az network vnet subnet show \
            -g "$vnetrg" --vnet-name "$vnetname" \
            -n "$subnetname" --query addressPrefixes[0] -o tsv)

        [[ "$subnetaddressprefix" == "$subnetcidr" ]] ||
            die "Subnet CIDR mismatch"

        issubnetowned=0
    else
        subnetsjson=$(az network vnet subnet list \
            -g "$vnetrg" --vnet-name "$vnetname" -o json)

        python3 -c '
import ipaddress,json,sys
new=ipaddress.ip_network(sys.argv[1])
for s in json.loads(sys.argv[2]):
    for p in s.get("addressPrefixes") or []:
        if new.overlaps(ipaddress.ip_network(p)):
            print("CIDR conflict:",s["name"],p)
            sys.exit(1)
' "$subnetcidr" "$subnetsjson" ||
            die "Subnet address conflict"

        az network vnet subnet create \
            -g "$vnetrg" --vnet-name "$vnetname" \
            -n "$subnetname" \
            --address-prefixes "$subnetcidr" \
            --delegations Microsoft.App/environments

        issubnetowned=1
    fi

    subnetresourceid=$(az network vnet subnet show \
        -g "$vnetrg" --vnet-name "$vnetname" \
        -n "$subnetname" --query id -o tsv)
}

repo_prepare() {
    local repositoryid
    repositoryid=$(az repos list \
        --organization "$devopsorgurl" --project "$devopsprojectname" \
        --query "[?name=='$reponame'].id | [0]" -o tsv)

    if [[ -z "$repositoryid" ]]; then
        az repos create \
            --organization "$devopsorgurl" \
            --project "$devopsprojectname" \
            --name "$reponame" >/dev/null
    fi

    repourl="${devopsorgurl%/}/${devopsprojectname}/_git/${reponame}"
    rm -rf "$workdirpath"
    git_cmd clone "$repourl" "$workdirpath"
    cd "$workdirpath"

    git config user.email "azure-mvp@local"
    git config user.name "Azure MVP"
    git checkout -B main 2>/dev/null || true
}

generate_files() {
    cat > Dockerfile <<EOF
FROM ${acrname}.azurecr.io/base/httpd:2.4.69-alpine
COPY itworks /usr/local/apache2/htdocs/index.html
EOF

    [[ -f itworks ]] || echo "version 1" > itworks

    cat > azure-pipelines.yml <<EOF
trigger:
  branches:
    include:
      - main

pool:
  vmImage: ubuntu-24.04

steps:
- task: AzureCLI@2
  displayName: Build, push and deploy
  inputs:
    azureSubscription: ${serviceconnectionname}
    scriptType: bash
    scriptLocation: inlineScript
    inlineScript: |
      set -euo pipefail
      IMAGE="${acrname}.azurecr.io/httpd-mvp:\$(Build.SourceVersion)"
      az acr login --name "${acrname}"
      docker build -t "\$IMAGE" .
      docker push "\$IMAGE"
      az containerapp update \\
        --name "${appname}" \\
        --resource-group "${rgname}" \\
        --image "\$IMAGE"
EOF

    git add Dockerfile itworks azure-pipelines.yml

    if ! git diff --cached --quiet; then
        git commit -m "Configure HTTPD MVP"
    fi

    git_cmd push -u origin main
}

create() {
    timer_start
    require_tools
    devops_login
    check_project

    [[ ! -f "$statefilepath" ]] || die "State exists; inspect first"
    [[ "$(az group exists -n "$rgname")" == "false" ]] ||
        die "Resource Group already exists; inspect first"

    network_check

    subscriptionid=$(az account show --query id -o tsv)
    tenantid=$(az account show --query tenantId -o tsv)
    subscriptionname=$(az account show --query name -o tsv)

    isacrnameavailable=$(az acr check-name \
        --name "$acrname" --query nameAvailable -o tsv)

    [[ "$isacrnameavailable" == "true" ]] ||
        die "ACR name unavailable"

    az group create -n "$rgname" -l "$azurelocation" \
        --tags managed-by=azure-mvp project="$devopsprojectname" >/dev/null

    isrgowned=1

    local spcreateoutput sppassword scid
    spcreateoutput=$(az ad sp create-for-rbac \
        --name "sp-${devopsprojectname}-devops" \
        --role Contributor \
        --scopes "/subscriptions/${subscriptionid}/resourceGroups/${rgname}" \
        -o json)
    spclientid=$(echo "$spcreateoutput" | jq -r .appId)
    sppassword=$(echo "$spcreateoutput" | jq -r .password)

    export AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY="$sppassword"
    az devops service-endpoint azurerm create \
        --azure-rm-service-principal-id "$spclientid" \
        --azure-rm-subscription-id "$subscriptionid" \
        --azure-rm-subscription-name "$subscriptionname" \
        --azure-rm-tenant-id "$tenantid" \
        --name "$serviceconnectionname" \
        --organization "$devopsorgurl" \
        --project "$devopsprojectname" >/dev/null
    unset AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY

    scid=$(az devops service-endpoint list \
        --organization "$devopsorgurl" \
        --project "$devopsprojectname" \
        --query "[?name=='$serviceconnectionname'].id | [0]" -o tsv)
    az devops service-endpoint update \
        --organization "$devopsorgurl" \
        --project "$devopsprojectname" \
        --id "$scid" \
        --enable-for-all true >/dev/null

    save_state

    az acr create -g "$rgname" -n "$acrname" \
        --sku Basic --admin-enabled true >/dev/null

    az acr import --name "$acrname" \
        --source "docker.io/library/$basedockerimage" \
        --image "base/httpd:2.4.69-alpine"

    az containerapp env create \
        -n "$envname" -g "$rgname" -l "$azurelocation" \
        --infrastructure-subnet-resource-id "$subnetresourceid"

    local acrpassword
    acrpassword=$(az acr credential show -n "$acrname" --query passwords[0].value -o tsv)

    az containerapp create \
        -n "$appname" -g "$rgname" \
        --environment "$envname" \
        --image "${acrname}.azurecr.io/base/httpd:2.4.69-alpine" \
        --registry-server "${acrname}.azurecr.io" \
        --registry-username "$acrname" \
        --registry-password "$acrpassword" \
        --ingress external --target-port 80 >/dev/null

    repo_prepare
    generate_files

    pipelineid=$(az pipelines create \
        --organization "$devopsorgurl" \
        --project "$devopsprojectname" \
        --name "p20261020-httpd" \
        --repository "$reponame" \
        --repository-type tfsgit \
        --branch main \
        --yaml-path azure-pipelines.yml \
        --skip-first-run true \
        --query id -o tsv)

    save_state

    log "CREATE completed"
    timer_end
}

deploy() {
    timer_start
    require_tools
    load_state
    devops_login

    local pipelinerunid pipelinerunstatus pipelinerunresult
    pipelinerunid=$(az pipelines run \
        --organization "$devopsorgurl" --project "$devopsprojectname" \
        --id "$pipelineid" --query id -o tsv)

    while true; do
        pipelinerunstatus=$(az pipelines runs show \
            --organization "$devopsorgurl" --project "$devopsprojectname" \
            --id "$pipelinerunid" --query status -o tsv)

        pipelinerunresult=$(az pipelines runs show \
            --organization "$devopsorgurl" --project "$devopsprojectname" \
            --id "$pipelinerunid" --query result -o tsv)

        [[ "$pipelinerunstatus" == "completed" ]] && break
        sleep 10
    done

    [[ "$pipelinerunresult" == "succeeded" ]] || die "Pipeline failed"

    log "DEPLOY completed"
    timer_end
}

update() {
    timer_start
    require_tools
    load_state
    devops_login

    local websitecontent="${2:-}"
    [[ -n "$websitecontent" ]] || die 'Usage: UPDATE "version 2"'

    repourl="${devopsorgurl%/}/${devopsprojectname}/_git/${reponame}"
    rm -rf "$workdirpath"
    git_cmd clone "$repourl" "$workdirpath"
    cd "$workdirpath"

    git config user.email "azure-mvp@local"
    git config user.name "Azure MVP"
    git checkout main

    printf '%s\n' "$websitecontent" > itworks
    git add itworks

    if ! git diff --cached --quiet; then
        git commit -m "Update website content"
        git_cmd push origin main
    fi

    log "UPDATE completed"
    timer_end
}

status() {
    timer_start
    require_tools
    load_state

    az group show -n "$rgname" -o table
    az acr show -g "$rgname" -n "$acrname" -o table
    az containerapp env show -g "$rgname" -n "$envname" -o table

    az containerapp show -g "$rgname" -n "$appname" \
        --query "{name:name,url:properties.configuration.ingress.fqdn}" \
        -o table || true

    az pipelines runs list \
        --organization "$devopsorgurl" --project "$devopsprojectname" \
        --pipeline-ids "$pipelineid" --top 5 -o table

    timer_end
}

cost() {
    timer_start
    require_tools
    load_state

    echo "Region: $azurelocation"
    echo "ACR SKU: Basic"
    echo "Container Apps: Consumption"
    echo "Actual cost depends on usage."

    az resource list -g "$rgname" \
        --query "[].{name:name,type:type,location:location}" -o table

    timer_end
}

destroy() {
    timer_start
    require_tools
    load_state

    echo "Project $devopsprojectname: PRESERVED"
    echo "Repository $reponame: PRESERVED"
    echo "VNet $vnetname: PRESERVED"
    echo "MVP Resource Group: $rgname"

    read -rp "Type DELETE-p20261020: " destroyconfirmation
    [[ "$destroyconfirmation" == "DELETE-p20261020" ]] ||
        die "Cancelled"

    [[ "$isrgowned" == "1" ]] ||
        die "Resource Group ownership not confirmed"

    if [[ -n "$pipelineid" ]]; then
        az pipelines delete \
            --organization "$devopsorgurl" \
            --project "$devopsprojectname" \
            --id "$pipelineid" --yes || true
    fi

    local scid
    scid=$(az devops service-endpoint list \
        --organization "$devopsorgurl" \
        --project "$devopsprojectname" \
        --query "[?name=='$serviceconnectionname'].id | [0]" \
        -o tsv 2>/dev/null || true)
    if [[ -n "$scid" ]]; then
        az devops service-endpoint delete \
            --organization "$devopsorgurl" \
            --project "$devopsprojectname" \
            --id "$scid" --yes
    fi

    if [[ -n "$spclientid" ]]; then
        az ad sp delete --id "$spclientid"
    fi

    az group delete -n "$rgname" --yes

    if [[ "$issubnetowned" == "1" ]]; then
        az network vnet subnet delete \
            -g "$vnetrg" --vnet-name "$vnetname" -n "$subnetname"
    fi

    rm -f "$statefilepath"
    rm -rf "$workdirpath"

    log "DESTROY completed"
    timer_end
}

case "${1:-}" in
    CREATE)  create ;;
    DEPLOY)  deploy ;;
    UPDATE)  update "$@" ;;
    STATUS)  status ;;
    COST)    cost ;;
    DESTROY) destroy ;;
    *)
        echo "Usage: $0 {CREATE|DEPLOY|UPDATE|STATUS|COST|DESTROY}"
        exit 1
        ;;
esac


##################


