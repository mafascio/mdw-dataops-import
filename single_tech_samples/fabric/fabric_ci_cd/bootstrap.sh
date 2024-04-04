#!/bin/bash
source .env

az account set --subscription "$AZURE_SUBSCRIPTION_ID"

# Domain Variables
fabric_domain_name="$FABRIC_DOMAIN_NAME"
fabric_subdomain_name="$FABRIC_SUBDOMAIN_NAME"
fabric_bearer_token="$FABRIC_BEARER_TOKEN"
fabric_project_name="$FABRIC_PROJECT_NAME"
location="$AZURE_LOCATION"
capacity_admin_email="$CAPACITY_ADMIN_EMAIL"
## APIs Endpoints
fabric_api_endpoint="https://api.fabric.microsoft.com/v1"
deployment_api_endpoint="$fabric_api_endpoint.0/myorg/pipelines"
# Azure DevOps details
azure_devops_details='{
    "gitProviderType":"'"AzureDevOps"'",
    "organizationName":"'"$ORGANIZATION_NAME"'",
    "projectName":"'"$PROJECT_NAME"'",
    "repositoryName":"'"$REPOSITORY_NAME"'",
    "branchName":"'"$BRANCH_NAME"'",
    "directoryName":"'"$DIRECTORY_NAME"'"
}'

# Flags to control the flow of the script (toggle as per the project requirements)
# TBD: Validate all the possible combinations of the flags. Also validate if the corresponding environment variables are set.
deploy_azure_resources="false"
create_workspaces="true"
setup_deployment_pipeline="true"
create_default_lakehouse="true"
create_notebooks="true"
create_pipelines="true"
trigger_notebook_execution="true"
trigger_pipeline_execution="true"
should_disconnect="false"
connect_to_git="true"
create_domain_and_attach_workspaces="false"
add_workspace_admins="true"
add_pipeline_admins="true"

# Derived variables (change as per the project requirements)
onelake_name="onelake"
workspace_names=("ws-$fabric_project_name-dev" "ws-$fabric_project_name-uat" "ws-$fabric_project_name-prd")
# Capacity resource details
resource_group_name="rg-$fabric_project_name"
capacity_name_suffix=$(echo "$fabric_project_name" | sed "s/'//g" | sed "s/-//g" | tr '[:upper:]' '[:lower:]')
fabric_capacity_name="cap$capacity_name_suffix"
# Deployment pipeline details
deployment_pipeline_name="dp-$fabric_project_name"
deployment_pipeline_desc="Deployment pipeline for $fabric_project_name"
# Workspace and item details
workspace_ids=()
lakehouse_name="lh_main"
lakehouse_desc="Lakehouse for $fabric_project_name"
notebook_names=("nb-city-safety" "nb-covid-data")
pipeline_names=("pl-covid-data")
# TBD: This notebook is used in "pl-covid-data" pipeline. This hardcoding needs to be removed.
pipeline_notebook="nb-covid-data"

function pause() {
    read -n 1 -s -r
}

function create_resource_group () {
    resource_group_name="$1"
    arm_output=$(az group create --name "$resource_group_name" --location "$location")
}

function deploy_azure_resources() {
    resource_group_name="$1"
    arm_output=$(az deployment group create \
        --resource-group "$resource_group_name" \
        --template-file infra/main.bicep \
        --parameters location="$AZURE_LOCATION" capacityName="$fabric_capacity_name" adminEmail="$capacity_admin_email" \
        --output json)

    if [[ -z $arm_output ]]; then
        echo >&2 "[E] ARM deployment failed."
        exit 1
    else
        echo "[I] Capacity '$fabric_capacity_name' created successfully."
    fi
}

function get_capacity_id() {
    response=$(curl -s -X GET -H "Authorization: Bearer $fabric_bearer_token" "$fabric_api_endpoint/capacities")
    capacity_id=$(echo "${response}" | jq -r --arg var "$fabric_capacity_name" '.value[] | select(.displayName == $var) | .id')
    echo "$capacity_id"
}

function create_workspace(){
    local workspace_name="$1"
    local capacity_id="$2"

    jsonPayload=$(cat <<EOF
{
    "DisplayName": "$workspace_name",
    "capacityId": "${capacity_id}",
    "description": "Workspace $workspace_name",
}
EOF
)

    curl -s -X POST "$fabric_api_endpoint/workspaces" \
        -o /dev/null \
        -H "Authorization: Bearer $fabric_bearer_token" \
        -H "Content-Type: application/json" \
        -d "${jsonPayload}"
}

function get_workspace_id() {
    workspace_name=$1
    get_workspaces_url="$fabric_api_endpoint/workspaces"
    workspaces=$(curl -s -H "Authorization: Bearer $fabric_bearer_token" "$get_workspaces_url" | jq -r '.value')
    workspace=$(echo "$workspaces" | jq -r --arg name "$workspace_name" '.[] | select(.displayName == $name)')
    workspace_id=$(echo "$workspace" | jq -r '.id')
    echo "$workspace_id"
}

function add_admin_to_workspace() {
    workspace_id=$1
    admin_ids=("${@:2}")   # this is an array of admin ids
    add_admin_url="$FABRIC_API_ENDPOINT/workspaces/$workspace_id/roleAssignments"
    
    echo "[I] Adding admins to workspace $workspace_id"

    for id in "${admin_ids[@]}"; do  
        add_admin_body=$(echo "{\"principal\": { \"id\": \"${id}\", \"type\": \"User\"}, \"role\": \"Admin\" }")
        response=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $FABRIC_BEARER_TOKEN" -d "$add_admin_body" "$add_admin_url" 2>&1)
        if [[ $(echo "${response}"|grep "PrincipalAlreadyHasWorkspaceRolePermissions"|wc -l) -ge 1 ]]; then  
            echo "[W]   The provided principal ${id} already has a role assigned in the workspace."
        else
            echo "[I]   Added $id as an admin."
        fi
    done
}


function create_deployment_pipeline() {
    deployment_pipeline_name=$1
    deployment_pipeline_desc=$2
    deployment_pipeline_body=$(cat <<EOF
{
    "displayName": "$deployment_pipeline_name",
    "description": "$deployment_pipeline_desc"
}
EOF
)
    create_deployment_pipeline_url="$deployment_api_endpoint"
    response=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $fabric_bearer_token" -d "$deployment_pipeline_body" "$create_deployment_pipeline_url")
    deployment_pipeline_id=$(echo "$response" | jq -r '.id')
    echo "[I] Created deployment pipeline '$deployment_pipeline_name' ($deployment_pipeline_id) successfully."
}

function get_deployment_pipeline_id() {
    deployment_pipeline_name=$1
    get_pipelines_url="$deployment_api_endpoint"
    pipelines=$(curl -s -H "Authorization: Bearer $fabric_bearer_token" "$get_pipelines_url" | jq -r '.value')
    pipeline=$(echo "$pipelines" | jq -r --arg name "$deployment_pipeline_name" '.[] | select(.displayName == $name)')
    pipeline_id=$(echo "$pipeline" | jq -r '.id')
    echo "$pipeline_id"
}

function get_deployment_pipeline_stages() {
    pipeline_id=$1
    get_pipeline_stages_url="$deployment_api_endpoint/$pipeline_id/stages"
    stages=$(curl -s -H "Authorization: Bearer $fabric_bearer_token" "$get_pipeline_stages_url" | jq -r '.value')
    echo "$stages"
}

function add_admin_to_pipeline() {
    pipeline_id=$1
    admin_ids=("${@:2}")   # this is an array of admin ids
    add_admin_url="$DEPLOYMENT_API_ENDPOINT/$pipeline_id/users"
    
    echo "[I] Adding admins to deployment pipeline $pipeline_id"

    for id in "${admin_ids[@]}"; do  
        add_admin_body=$(echo "{\"identifier\":  \"${id}\", \"principalType\": \"User\", \"accessRight\": \"Admin\" }")
        response=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $FABRIC_BEARER_TOKEN" -d "$add_admin_body" "$add_admin_url" 2>&1)
        if [[ $(echo "${response}"|grep "errorCode"|wc -l) -ge 1 ]]; then  
            echo "[W]   The admin access addition for ${id} resulted in error: $response"
        else
            echo "[I]   Added $id as an admin."
        fi
    done
}

function unassign_workspace_from_stage() {
    pipeline_id=$1
    stage_id=$2
    pipeline_unassignment_url="$deployment_api_endpoint/$pipeline_id/stages/$stage_id/unassignWorkspace"
    pipeline_unassignment_body={}

    curl -s -X POST -H "Authorization: Bearer $fabric_bearer_token" -H "Content-Type: application/json" -d "$pipeline_unassignment_body" "$pipeline_unassignment_url"
    echo "[I] Unassigned workspace from stage '$stage_id' successfully."
}

function assign_workspace_to_stage() {
    pipeline_id=$1
    stage_id=$2
    workspace_id=$3
    pipeline_assignment_url="$deployment_api_endpoint/$pipeline_id/stages/$stage_id/assignWorkspace"
    pipeline_assignment_body=$(cat <<EOF
{
    "workspaceId": "$workspace_id"
}
EOF
)
    curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $fabric_bearer_token" -d "$pipeline_assignment_body" "$pipeline_assignment_url"
    echo "[I] Assigned workspace '$workspace_id' to stage '$stage_id' successfully."
}

function lakehouse_payload() {
    display_name=$1
    description=$2
    cat <<EOF
{
    "displayName": "$display_name",
    "description": "$description",
    "type": "Lakehouse"
}
EOF
}

function notebook_payload() {
    display_name=$1
    payload=$2
    cat <<EOF
{
    "displayName": "$display_name",
    "type": "Notebook",
    "definition" : {
        "format": "ipynb",
        "parts": [
            {
                "path": "artifact.content.ipynb",
                "payload": "$payload",
                "payloadType": "InlineBase64"
            }
        ]
    }
}
EOF
}

function data_pipeline_payload() {
    display_name=$1
    description=$2
    payload=$3
    cat <<EOF
{
    "displayName": "$display_name",
    "description": "$description",
    "type":"DataPipeline",
    "definition" : {
        "parts" : [
            {
                "path": "pipeline-content.json",
                "payload": "${payload}",
                "payloadType": "InlineBase64"
            }
        ]
    }
}
EOF
}

function create_item() {
    workspace_id=$1
    item_type=$2
    display_name=$3
    description=$4
    payload=$5
    create_item_url="$fabric_api_endpoint/workspaces/$workspace_id/items"
    case "$item_type" in
        "Lakehouse")
            create_item_body=$(lakehouse_payload "$display_name" "$description")
            ;;
        "Notebook")
            create_item_body=$(notebook_payload "$display_name" "$payload")
            ;;
        "DataPipeline")
            create_item_body=$(data_pipeline_payload "$display_name" "$description" "$payload")
            ;;
        *)
            echo "[E] Invalid item type '$item_type'."
            ;;
    esac

    response=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $fabric_bearer_token" -d "$create_item_body" "$create_item_url")
    if [[ -n "$response" ]] && [[ "$response" != "null" ]]; then
        if echo "$response" | jq '.id' > /dev/null 2>&1; then
            item_id=$(echo "$response" | jq -r '.id')
            echo "[I] Created $item_type '$display_name' ($item_id) successfully."
        else
            echo "[E] $item_type '$display_name' creation failed."
            echo "[E] $response"
        fi
    else
        sleep 10
        item_id=$(get_item_by_name_type "$workspace_id" "$item_type" "$display_name")
        echo "[I] Created $item_type '$display_name' ($item_id) successfully."
    fi
}

function get_item_by_name_type() {
    workspace_id=$1
    item_type=$2
    item_name=$3

    get_items_url="$fabric_api_endpoint/workspaces/$workspace_id/items"
    items=$(curl -s -X GET -H "Authorization: Bearer $fabric_bearer_token" "$get_items_url" | jq -r '.value')
    item=$(echo "$items" | jq -r --arg name "$item_name" --arg type "$item_type" '.[] | select(.displayName == $name and .type == $type)')
    item_id=$(echo "$item" | jq -r '.id')
    echo "$item_id"
}

function disconnect_workspace_from_git() {
    workspace_id=$1
    disconnect_workspace_url="$fabric_api_endpoint/workspaces/$workspace_id/git/disconnect"
    disconnect_workspace_body={}
    response=$(curl -s -X POST -H "Authorization : Bearer $fabric_bearer_token" -H "Content-Type: application/json" -d "$disconnect_workspace_body" "$disconnect_workspace_url")
    if [[ -n "$response" ]] && [[ "$response" != "null" ]]; then
        error_code=$(echo "$response" | jq -r '.errorCode')
        if [[ "$error_code" = "WorkspaceNotConnectedToGit" ]]; then
            echo "[I] Workspace is not connected to git."
        else
            echo "[E] The workspace disconnection from git failed."
            echo "[E] $response"
        fi
    else
        echo "[I] Workspace disconnected from the git repository."
    fi
}

function initialize_connection() {
    workspace_id=$1
    initialize_connection_url="$fabric_api_endpoint/workspaces/$workspace_id/git/initializeConnection"
    initialize_connection_body='{"InitializationStrategy": "PreferWorkspace"}'
    response=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization : Bearer $fabric_bearer_token" -d "$initialize_connection_body" "$initialize_connection_url")
    echo "[I] The Git connection has been successfully initialized."
}

function connect_workspace_to_git() {
    workspace_id=$1
    git_provider_details=$2
    connect_workspace_url="$fabric_api_endpoint/workspaces/$workspace_id/git/connect"
    connect_workspace_body='{"gitProviderDetails": '"$git_provider_details"'}'
    response=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $fabric_bearer_token" -d "$connect_workspace_body" "$connect_workspace_url")
    if [[ -n "$response" ]] && [[ "$response" != "null" ]]; then
        error_code=$(echo "$response" | jq -r '.errorCode')
        if [[ "$error_code" = "WorkspaceAlreadyConnectedToGit" ]]; then
            echo "[I] Workspace is already connected to git."
        else
            echo "[E] The workspace connection to git failed."
            echo "[E] $response"
        fi
    else
        echo "[I] Workspace connected to the git repository."
        initialize_connection "$dev_workspace_id"
    fi
}

function get_git_status() {
    workspace_id=$1
    get_git_status_url="$fabric_api_endpoint/workspaces/$workspace_id/git/status"
    response=$(curl -s -X GET -H "Authorization : Bearer $fabric_bearer_token" "$get_git_status_url")
    workspace_head=$(echo "$response" | jq -r '.workspaceHead')
    echo "$workspace_head"
}

function commit_all_to_git() {
    workspace_id=$1
    workspace_head=$2
    commit_message=$3
    commit_all_url="$fabric_api_endpoint/workspaces/$workspace_id/git/commitToGit"
    commit_all_body=$(cat <<EOF
{
    "mode": "All",
    "comment": "$commit_message",
    "workspaceHead": "$workspace_head"
}
EOF
)
    response=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $fabric_bearer_token" -d "$commit_all_body" "$commit_all_url")
    if [[ -n "$response" ]] && [[ "$response" != "null" ]]; then
        error_code=$(echo "$response" | jq -r '.errorCode')
        if [[ "$error_code" = "NoChangesToCommit" ]]; then
            echo "[I] There are no changes to commit."
        else
            echo "[E] Committing workspace changes to git failed."
            echo "[E] $response"
        fi
    else
        echo "[I] Committed workspace changes to git successfully."
    fi
}

function execute_notebook() {
    workspace_id=$1
    item_id=$2
    onelake_name=$3
    workspace_name=$4
    lakehouse_name=$5
    execute_notebook_url="$fabric_api_endpoint/workspaces/$workspace_id/items/$item_id/jobs/instances?jobType=RunNotebook"
    execute_notebook_body=$(cat <<EOF
{
    "executionData": {
        "parameters": {
            "onelake_name": {
                "value": "$onelake_name",
                "type": "string"
            },
            "workspace_name": {
                "value": "$workspace_name",
                "type": "string"
            },
            "lakehouse_name": {
                "value": "$lakehouse_name",
                "type": "string"
            }
        },
        "configuration": {
            "useStarterPool": true
        }
    }
}
EOF
)
    # TBD: Check the notebook execution via polling long running operation. Read header response by using "-i" flag.
    response=$(curl -s -X POST -H "Authorization: Bearer $fabric_bearer_token" -H "Content-Type: application/json" -d "$execute_notebook_body" "$execute_notebook_url")
    if [[ -n "$response" ]] && [[ "$response" != "null" ]]; then
        echo "[E] Notebook execution failed."
        echo "[E] $response"
    else
        echo "[I] Notebook execution triggered successfully."
    fi
}

function execute_pipeline() {
    workspace_id=$1
    item_id=$2
    onelake_name=$3
    workspace_name=$4
    lakehouse_name=$5
    execute_pipeline_url="$fabric_api_endpoint/workspaces/$workspace_id/items/$item_id/jobs/instances?jobType=Pipeline"
    execute_pipeline_body=$(cat <<EOF
{
    "executionData": {
        "parameters": {
            "onelake_name": "$onelake_name",
            "workspace_name": "$workspace_name",
            "lakehouse_name": "$lakehouse_name"
        }
    }
}
EOF
)
    # TBD: Check the notebook execution via polling long running operation. Read header response by using "-i" flag.
    response=$(curl -s -X POST -H "Authorization: Bearer $fabric_bearer_token" -H "Content-Type: application/json" -d "$execute_pipeline_body" "$execute_pipeline_url")
    if [[ -n "$response" ]] && [[ "$response" != "null" ]]; then
        echo "[E] Data pipeline execution failed."
        echo "[E] $response"
    else
        echo "[I] Data pipeline execution triggered successfully."
    fi
}

function get_domain_id() {
    domain_name=$1
    get_domains_url="$fabric_api_endpoint/admin/domains"
    domains=$(curl -s -H "Authorization: Bearer $fabric_bearer_token" "$get_domains_url" | jq -r '.domains')
    domain=$(echo "$domains" | jq -r --arg name "$domain_name" '.[] | select(.displayName == $name)')
    domain_id=$(echo "$domain" | jq -r '.id')
    echo "$domain_id"
}

function create_domain() {
    domain_name=$1
    parent_domain_id=$2
    create_domain_payload=$(cat <<EOF
{
    "displayName": "$domain_name",
    "description": "Fabric domain $domain_name",
    "parentDomainId": "$parent_domain_id"
}
EOF
)
    create_domain_url="$fabric_api_endpoint/admin/domains"
    response=$(curl -s -X POST -H "Authorization: Bearer $fabric_bearer_token" -H "Content-Type: application/json" -d "$create_domain_payload" "$create_domain_url")
    domain_id=$(echo "$response" | jq -r '.id')
    if [[ -n "$domain_id" ]]; then
        if [[ -n "$parent_domain_id" ]]; then
            echo "[I] Created subdomain '$domain_name' ($domain_id) successfully."
        else
            echo "[I] Created domain '$domain_name' ($domain_id) successfully."
        fi
    else
        echo "[E] Domain creation failed."
        echo "[E] $response"
    fi
}

function assign_domain_workspaces_by_ids() {
    domain_id=$1
    shift
    workspace_ids=("$@")
    for items in "${workspace_ids[@]}"; do
        temp_string+="\"$items\","
    done
    workspace_ids_as_string=$(echo "$temp_string" | sed 's/.$//')
    assign_domain_workspaces_payload=$(cat <<EOF
{
    "workspacesIds": [${workspace_ids_as_string}]
}
EOF
)
    assign_domain_workspaces_url="$fabric_api_endpoint/admin/domains/$domain_id/assignWorkspaces"
    response=$(curl -s -X POST -H "Authorization: Bearer $fabric_bearer_token" -H "Content-Type: application/json" -d "$assign_domain_workspaces_payload" "$assign_domain_workspaces_url")
    if [[ -n "$response" ]] && [[ "$response" != "null" ]]; then
        echo "[E] Assigning workspaces to (sub)domain failed."
        echo "[E] $response"
    else
        echo "[I] Assigned workspaces to the (sub)domain successfully."
    fi
}

function add_admin_to_workspace() {
    workspace_id=$1
    admin_ids=("${@:2}")   # this is an array of admin ids
    add_admin_url="$FABRIC_API_ENDPOINT/workspaces/$workspace_id/roleAssignments"

    echo "[I] Adding admins to workspace $workspace_id"

    for id in "${admin_ids[@]}"; do  
        add_admin_body=$(echo "{\"principal\": { \"id\": \"${id}\", \"type\": \"User\"}, \"role\": \"Admin\" }")
        response=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $FABRIC_BEARER_TOKEN" -d "$add_admin_body" "$add_admin_url" 2>&1)
        if [[ $(echo "${response}"|grep "PrincipalAlreadyHasWorkspaceRolePermissions"|wc -l) -ge 1 ]]; then  
            echo "[W]   The provided principal ${id} already has a role assigned in the workspace."
        else
            echo "[I]   Added $id as an admin."
        fi
    done
}

function add_admin_to_pipeline() {
    pipeline_id=$1
    admin_ids=("${@:2}")   # this is an array of admin ids
    add_admin_url="$DEPLOYMENT_API_ENDPOINT/$pipeline_id/users"

    echo "[I] Adding admins to deployment pipeline $pipeline_id"

    for id in "${admin_ids[@]}"; do  
        add_admin_body=$(echo "{\"identifier\":  \"${id}\", \"principalType\": \"User\", \"accessRight\": \"Admin\" }")
        response=$(curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $FABRIC_BEARER_TOKEN" -d "$add_admin_body" "$add_admin_url" 2>&1)
        if [[ $(echo "${response}"|grep "errorCode"|wc -l) -ge 1 ]]; then  
            echo "[W]   The admin access addition for ${id} resulted in error: $response"
        else
            echo "[I]   Added $id as an admin."
        fi
    done
}

echo "[I] ############ START ############"

echo "[I] ############ Fabric Token Validation ############"
token_response=$(curl -s -X GET -H "Content-Type: application/json" -H "Authorization: Bearer $fabric_bearer_token" "$fabric_api_endpoint/workspaces/")

if echo "${token_response}" | grep "TokenExpired"; then  
    echo "[E] Fabric token has expired. Please generate a new token and update the .env file."
    exit 1
else
    echo "[I] Fabric token is valid."
fi

echo "[I] ############ Azure Resource Deployment ############"
if [[ "$deploy_azure_resources" = "true" ]]; then
    echo "[I] Creating resource group '$resource_group_name'"
    create_resource_group "$resource_group_name"

    echo "[I] Deploying Azure resources to resource group '$resource_group_name'"
    deploy_azure_resources "$resource_group_name"
else
    echo "[I] Variable 'deploy_azure_resources' set to $deploy_azure_resources, skipping Azure resource deployment."
fi

echo "[I] ############ Workspace Creation ############"
if [[ "$create_workspaces" = "true" ]]; then
    capacity_id=$(get_capacity_id)
    echo "[I] Fabric capacity is '$fabric_capacity_name' ($capacity_id)"

    for ((i=0; i<${#workspace_names[@]}; i++)); do
        workspace_ids[i]=$(get_workspace_id "${workspace_names[$i]}")
        if [[ -n "${workspace_ids[i]}" ]]; then
            echo "[W] Workspace: '${workspace_names[$i]}' (${workspace_ids[i]}) already exists."
            echo "[W] Please verify the attached capacity manually."
        else
            create_workspace "${workspace_names[$i]}" "$capacity_id"
            workspace_ids[i]=$(get_workspace_id "${workspace_names[$i]}")
            echo "[I] Created workspace '${workspace_names[i]}' (${workspace_ids[i]})"
        fi
    done
else
    echo "[I] Variable 'create_workspaces' set to $create_workspaces, skipping workspace creation."
fi

# TBD: Name each stage in the deployment pipeline.
# TBD: Remove dependency on "create_workspaces" variable set to "true" for the setup of deployment pipeline.
echo "[I] ############ Deployment Pipeline Creation ############"
if [[ "$setup_deployment_pipeline" = "true" ]]; then
    pipeline_id=$(get_deployment_pipeline_id "$deployment_pipeline_name")

    if [[ -n "$pipeline_id" ]]; then
        echo "[I] Deployment pipeline '$deployment_pipeline_name' ($pipeline_id) already exists."
    else
        echo "[I] No deployment pipeline with name '$deployment_pipeline_name' found, creating one."
        create_deployment_pipeline "$deployment_pipeline_name" "$deployment_pipeline_desc"
        pipeline_id=$(get_deployment_pipeline_id "$deployment_pipeline_name")
    fi

    pipeline_stages=$(get_deployment_pipeline_stages "$pipeline_id")

    for ((i=0; i<${#workspace_names[@]}; i++)); do
        workspace_name="${workspace_names[i]}"
        workspace_id="${workspace_ids[i]}"
        echo "[I] Workspace $workspace_name ($workspace_id)"
        existing_workspace_id=$(echo "$pipeline_stages" | jq -r --arg order "$i" '.[] | select(.order == ($order | tonumber) and .workspaceId) | .workspaceId')
        echo "[I] Existing workspace for stage '$i' is $existing_workspace_id."
        if [[ -z "$existing_workspace_id" ]]; then
            assign_workspace_to_stage "$pipeline_id" "$i" "$workspace_id"
        elif [[ "$existing_workspace_id" == "$workspace_id" ]]; then
            echo "[I] The pipeline deployment stage '$i' has workspace '$workspace_name' ($workspace_id) already assigned to it."
        else
            echo "[I] The pipeline deployment stage '$i' has a different workspace '$workspace_name' ($workspace_id) assigned, reassigning."
            unassign_workspace_from_stage "$pipeline_id" "$i"
            assign_workspace_to_stage "$pipeline_id" "$i" "$workspace_id"
        fi
    done
else
    echo "[I] Variable 'setup_deployment_pipeline' set to $setup_deployment_pipeline, skipping deployment pipeline creation."
fi

echo "[I] ############ Adding admin IDS to Workspaces ############"
if [[ "$add_workspace_admin" = "true" ]]; then
    for ((i=0; i<${#workspace_names[@]}; i++)); do
        add_admin_to_workspace "${workspace_ids[i]}" "${ADMIN_ACCESS_IDS[@]}"  
        echo "[I] Updated workspace '${workspace_names[i]}' with admin access."
    done
else
    echo "[I] Variable 'add_workspace_admin' set to $add_workspace_admin, skipping admin ids addition to workspace."
fi

echo "[I] ############ Adding admin IDS to Deployment pipeline ############"
if [[ "$add_pipeline_admin" = "true" ]]; then
    add_admin_to_pipeline "$pipeline_id" "${PIPELINE_ADMIN_IDS[@]}"  
    echo "[I] Updated deployment pipeline '${workspace_names[i]}' with admin access."
else
    echo "[I] Variable 'add_pipeline_admin' set to $add_pipeline_admin, skipping admin ids addition to deployment pipeline."
fi

dev_workspace_id="${workspace_ids[0]}"
dev_workspace_name="${workspace_names[0]}"

echo "[I] ############ Lakehouse Creation (DEV) ############"
if [[ "$create_default_lakehouse" = "true" ]]; then
    item_id=$(get_item_by_name_type "$dev_workspace_id" "Lakehouse" "$lakehouse_name")
    if [[ -n "$item_id" ]]; then
        echo "[I] Lakehouse $lakehouse_name ($item_id) already exists."
    else
        create_item "$dev_workspace_id" "Lakehouse" "$lakehouse_name" "$lakehouse_desc" ""
    fi
else
    echo "[I] Variable 'create_default_lakehouse' set to $create_default_lakehouse, skipping lakehouse creation."
fi

# TBD: If the notebook exists, update the notebook with the latest version.
# https://learn.microsoft.com/en-us/rest/api/fabric/core/items/update-item-definition?tabs=HTTP
echo "[I] ############ Notebooks Creation (DEV) ############"
if [[ "$create_notebooks" = "true" ]]; then
    for ((i=0; i<${#notebook_names[@]}; i++)); do
        notebook_name="${notebook_names[i]}"
        file_path="./src/notebooks/${notebook_name}.ipynb"
        base64_data=$(base64 -i "$file_path")
        item_id=$(get_item_by_name_type "$dev_workspace_id" "Notebook" "$notebook_name")
        if [[ -n "$item_id" ]]; then
            echo "[I] Notebook '$notebook_name' ($item_id) already exists, skipping the upload."
        else
            create_item "$dev_workspace_id" "Notebook" "$notebook_name" "Notebook $notebook_name" "$base64_data"
        fi
    done
else
    echo "[I] Variable 'create_notebooks' set to $create_notebooks, skipping notebook(s) upload."
fi

# TBD: If the pipeline exists, update the pipeline with the latest version.
# https://learn.microsoft.com/en-us/rest/api/fabric/core/items/update-item-definition?tabs=HTTP
echo "[I] ############ Data Pipelines Creation (DEV) ############"
if [[ "$create_pipelines" = "true" ]]; then
    for ((i=0; i<${#pipeline_names[@]}; i++)); do
        pipeline_name="${pipeline_names[i]}"
        item_id=$(get_item_by_name_type "$dev_workspace_id" "DataPipeline" "$pipeline_name")

        if [[ -n "$item_id" ]]; then
            echo "[I] Data pipeline '$pipeline_name' ($item_id) already exists, skipping the upload."
        else
            # TBD: Remove handcoding of notebook name from here.
            notebook_id=$(get_item_by_name_type "$dev_workspace_id" "Notebook" "$pipeline_notebook")
            file_path="./src/data-pipelines/${pipeline_name}-content.json"
            base64_data=$(sed -e "s/<<notebook_id>>/${notebook_id}/g" -e "s/<<workspace_id>>/${dev_workspace_id}/g" "$file_path" | base64)
            create_item "$dev_workspace_id" "DataPipeline" "$pipeline_name" "Data pipeline for executing notebook" "$base64_data"
        fi
    done
else
    echo "[I] Variable 'create_pipelines' set to $create_pipelines, skipping data pipeline(s) upload."
fi

echo "[I] ############ Triggering Data Pipeline Execution (DEV) ############"
if [[ "$trigger_pipeline_execution" = "true" ]]; then
    for ((i=0; i<${#pipeline_names[@]}; i++)); do
        pipeline_name="${pipeline_names[i]}"
        item_id=$(get_item_by_name_type "$dev_workspace_id" "DataPipeline" "$pipeline_name")
        execute_pipeline "$dev_workspace_id" "$item_id" "$onelake_name" "$dev_workspace_name" "$lakehouse_name"
        # TBD: Check the notebook execution via polling long running operation.
    done
else
    echo "[I] Variable 'trigger_pipeline_execution' set to $trigger_pipeline_execution, skipping data pipeline execution."
fi

echo "[I] ############ Triggering Notebook Execution (DEV) ############"
if [[ "$trigger_notebook_execution" = "true" ]]; then
    # TBD: Remove hardcoding of the notebook name from here.
    notebook_name="nb-city-safety"
    item_id=$(get_item_by_name_type "$dev_workspace_id" "Notebook" "$notebook_name")
    execute_notebook "$dev_workspace_id" "$item_id" "$onelake_name" "$dev_workspace_name" "$lakehouse_name"
else
    echo "[I] Variable 'trigger_notebook_execution' set to $trigger_notebook_execution, skipping notebook execution."
fi

echo "[I] ############ GIT Integration (DEV) ############"
if [[ "$connect_to_git" = "true" ]]; then
    if [ "$should_disconnect" = true ]; then
        disconnect_workspace_from_git "$dev_workspace_id"
    fi
    connect_workspace_to_git "$dev_workspace_id" "$azure_devops_details"
    workspace_head=$(get_git_status "$dev_workspace_id")
    echo "[I] Workspace head is '${workspace_head}'"
    commit_all_to_git "$dev_workspace_id" "$workspace_head" "Committing initial changes"
else
    echo "[I] Variable 'connect_to_git' set to $connect_to_git, skipping git integration, commit and push."
fi

echo "[I] ############ Creating (sub)domain attaching workspaces to it ############"
if [[ "$create_domain_and_attach_workspaces" = "true" ]]; then
    domain_id=$(get_domain_id "$fabric_domain_name")
    if [[ -n "$domain_id" ]]; then
        echo "[I] Domain '$fabric_domain_name' ($domain_id) already exists."
    else
        create_domain "$fabric_domain_name" ""
        domain_id=$(get_domain_id "$fabric_domain_name")
    fi

    if [[ -n "$fabric_subdomain_name" ]]; then
        subdomain_id=$(get_domain_id "$fabric_subdomain_name")
        if [[ -n "$subdomain_id" ]]; then
            echo "[I] Subdomain '$fabric_subdomain_name' ($subdomain_id) already exists."
        else
            create_domain "$fabric_subdomain_name" "$domain_id"
            subdomain_id=$(get_domain_id "$fabric_subdomain_name")
        fi
        assign_domain_workspaces_by_ids "$subdomain_id" "${workspace_ids[@]}"
    else
        assign_domain_workspaces_by_ids "$domain_id" "${workspace_ids[@]}"
    fi
else
    echo "[I] Variable 'create_domain_and_attach_workspaces' set to $create_domain_and_attach_workspaces, skipping domain creation and workspace assignment."
fi

echo "[I] ############ Adding admin IDS to Workspaces ############"
if [[ "$add_workspace_admins" = "true" ]]; then
    for ((i=0; i<${#workspace_names[@]}; i++)); do
        add_admin_to_workspace "${workspace_ids[i]}" "${ADMIN_ACCESS_IDS[@]}"  
        echo "[I] Updated workspace '${workspace_names[i]}' with admin access."
    done
else
    echo "[I] Variable 'add_workspace_admin' set to $add_workspace_admins, skipping admin ids addition to workspace."
fi

echo "[I] ############ Adding admin IDS to Deployment pipeline ############"
if [[ "$add_pipeline_admins" = "true" ]]; then
    add_admin_to_pipeline "$pipeline_id" "${PIPELINE_ADMIN_IDS[@]}"  
    echo "[I] Updated deployment pipeline '${workspace_names[i]}' with admin access."
else
    echo "[I] Variable 'add_pipeline_admin' set to $add_pipeline_admins, skipping admin ids addition to deployment pipeline."
fi

echo "[I] ############ END ############"
