#!/bin/bash

SUPRA_DOCKER_IMAGE=""
SCRIPT_EXECUTION_LOCATION="$(pwd)/supra_configs_mainnet"
CONFIG_FILE="$(pwd)/operator_config_mainnet.toml"
BASE_PATH="$(pwd)"

GITHUB_URL_SSH="git@github.com:Entropy-Foundation/supra-nodeops-data.git"

GRAFANA="https://raw.githubusercontent.com/Entropy-Foundation/supra-node-monitoring-tool/master/nodeops-monitoring-telegraf.sh"
GRAFANA_CENTOS="https://raw.githubusercontent.com/Entropy-Foundation/supra-node-monitoring-tool/master/nodeops-monitoring-telegraf-centos.sh"

create_folder_and_files() {
    touch operator_config_mainnet.toml
    if [ ! -d "supra_configs_mainnet" ]; then
        mkdir supra_configs_mainnet
    else
        echo ""
    fi
}

extract_ip() {
    local ip=$(grep -oP 'ip_address\s*=\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$CONFIG_FILE")
    echo "$ip"
}

display_questions() {
    echo "1. Select Phase I - Generate Operator Keys"
    echo "2. Select Phase II - Perform Signing Operation"
    echo "3. Select Phase III - Create Genesis Blob"
    echo "4. Select Phase IV - Start the node and other services"
    echo "5. Select Phase V - Restart the network using snapshot"
    echo "6. Select phase VI - Update the binaries of network"
    echo "7. Exit"
}

check_permissions() {
    folder_path="$1"
    if [ ! -w "$folder_path" ]; then
        echo "" 
        echo ""
        echo ""
        echo "Please check write permissions."
        echo "" 
        echo "TERMINATING SCRIPT" 
        exit 1
    fi  
}

check_prerequisites() {
    # Check if Docker is installed
    if ! command -v docker &>/dev/null; then
        echo "Docker is not installed. Please install Docker before proceeding."
        echo "Terminating Script"
        echo " "
        exit 1
    fi 

    # Check if gCloud is installed
    if ! command -v gcloud &>/dev/null; then
        echo "gCloud is not installed. Please install gCloud before proceeding."
        exit 1
    fi

    # Check if the user is not root
    if [ "$(id -u)" = "0" ]; then
        echo "You are running as root. Please run as a non-root user."
        echo ""
        exit 1
    fi  

    # Check if toml-cli is installed
    if ! command -v toml &> /dev/null; then
        echo "toml-cli could not be found. Please install it to proceed."
        echo "command : cargo install toml-cli"
        exit 1
    fi 

    # Check if sha256sum is installed
    if ! command -v sha256sum &> /dev/null; then
        echo "sha256sum is not installed."
        exit 1
    fi

    # Check if openssl is installed
    if ! command -v openssl &> /dev/null; then
        echo "openssl is not installed."
        exit 1
    fi

    # Check if zip is installed
    if ! command -v zip &> /dev/null; then
        echo "zip is not installed, please install zip manually."
        exit 1
    fi

    # Check if expect is installed
    if ! command -v expect &> /dev/null; then
        # Check package manager and provide instructions
        if [ -f /etc/apt/sources.list ]; then
            package_manager="sudo apt install"
        elif [ -f /etc/yum.repos.d/ ]; then
            package_manager="sudo yum install"
        else
            echo "**WARNING: Could not identify package manager, Please install expect manually."
            exit 1
        fi
        echo "Expect is not installed. Install it with:"
        echo "$package_manager expect"
        exit 1
    fi
}


prerequisites() {
    echo ""
    echo "CHECKING PREREQUISITES"
    echo ""
    check_prerequisites
    echo "All Checks Passed: ✔ "
}

archive_and_remove_phase_1_files() {
    # Navigate to the script execution location
    cd "$SCRIPT_EXECUTION_LOCATION" || {
        echo "ERROR: Unable to navigate to script execution location."
        exit 1
    }

    smr_public_key_exists=false
    validator_public_identity_exists=false
    smr_settings_exists=false

    # Check if the specific Phase 1 files exist
    [ -f "smr_public_key.json" ] && smr_public_key_exists=true
    [ -f "validator_public_identity.toml" ] && validator_public_identity_exists=true
    [ -f "smr_settings.toml" ] && smr_settings_exists=true

    # Proceed only if any of the files exist
    if $smr_public_key_exists || $validator_public_identity_exists || $smr_settings_exists; then
        
        # Handle existing archives
        if [ -f "phase_1_archived.zip" ]; then
            echo "Existing phase_1_archived.zip found."
            if [ -f "old-phase_1_archived.zip" ]; then
                echo "Adding the new archive to old-phase_1_archived.zip."
                # Create a temporary zip for new files and merge into old archive
                zip -r phase_1_archived_temp.zip ./* > /dev/null
                zip -r old-phase_1_archived.zip phase_1_archived_temp.zip > /dev/null
                rm phase_1_archived_temp.zip
                echo "Successfully merged new archive into old-phase_1_archived.zip."
            else
                mv phase_1_archived.zip old-phase_1_archived.zip
                echo "Renamed phase_1_archived.zip to old-phase_1_archived.zip."
            fi
        fi
        
        # Archive all files and directories
        echo "Archiving Phase 1 files..."
        zip -r phase_1_archived.zip ./* > /dev/null
        echo "✔ All files and folders archived successfully as phase_1_archived.zip."
        
        # Remove all files except the new archive
        echo "Cleaning up the directory..."
        find . -type f ! -name 'phase_1_archived.zip' -exec rm -f {} +
        find . -type d ! -name '.' -exec rm -rf {} +
        
        # Clear specific logs
        echo "Clearing supra_node_logs..."
        rm -rf supra_node_logs/*

        echo "All files and folders removed successfully, except phase_1_archived.zip."
    else
        echo "No Phase 1 files found to archive."
    fi

    # Return to the parent directory
    cd .. || {
        echo "ERROR: Unable to return to the parent directory."
        exit 1
    }
}


list_running_docker_containers() {
    running_containers=$(docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}")
    if [ -z "$running_containers" ]; then
        echo "No running Docker containers."
    else
        echo "Currently running Docker containers:"
        echo "$running_containers"
    fi
}

is_supra_running() {
    if docker ps --format '{{.Names}}' | awk '$1 ~ /^supra_mainnet_/' | grep -q .; then
        return 0  
    else
        return 1 
    fi
}

remove_docker_container() {
    local container_name=$1
    if docker ps -a --format '{{.Names}}' | grep -Eq "^$container_name$"; then
        docker stop $container_name
        wait
        docker rm $container_name
        echo "✔ Container $container_name removed."
    else
        echo "Container $container_name does not exist."
    fi
}

remove_container_prompt() {
    echo ""
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.CreatedAt}}\t{{.Status}}\t{{.Image}}"
    echo ""
    echo ""
    read -p "Enter the name of the Docker container you want to remove: " container_name
    echo "Please Wait..."
    remove_docker_container "$container_name"
}

function configure_operator() {
    echo ""
    echo "Input ip address and password for validator node"
    echo ""
    
    local valid_ip_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"

    function validate_ip() {
        local ip=$1
        if [[ $ip =~ $valid_ip_regex ]]; then
            IFS='.' read -r -a octets <<< "$ip"
            for octet in "${octets[@]}"; do
                if ((octet < 0 || octet > 255)); then
                    return 1
                fi
            done
            return 0
        else
            return 1
        fi
    }

    while true; do
        read -p "Enter IP address: " ip_address
        if validate_ip "$ip_address"; then
            break
        else
            echo "Invalid IP address. Please enter a valid IP address."
        fi
    done

    read -sp "Enter password: " password
    echo

    encoded_password=$(echo -n "$password" | base64)
    toml_file="$CONFIG_FILE"
    tmp_file=$(mktemp)

    grep -v '^ip_address' "$toml_file" | grep -v '^password' > "$tmp_file"

    echo "ip_address = \"$ip_address\"" >> "$tmp_file"
    echo "password = \"$encoded_password\"" >> "$tmp_file"
    mv "$tmp_file" "$toml_file"
}

function create_supra_container() {
    echo ""
    echo "CREATE DOCKER CONTAINER"
    echo "" 
    local supra_docker_image="$1"

    USER_ID=$(id -u)
    GROUP_ID=$(id -g)
    ip=$(extract_ip $CONFIG_FILE)

    if [[ -z "$ip" ]]; then
        echo "IP address not found in $CONFIG_FILE"
        return 1
    fi
    
    docker run --name "supra_mainnet_$ip" \
        -v ./supra_configs_mainnet:/supra/configs \
        --user "$USER_ID:$GROUP_ID" \
        -e "SUPRA_HOME=/supra/configs" \
        -e "SUPRA_LOG_DIR=/supra/configs/supra_node_logs" \
        -e "SUPRA_MAX_LOG_FILE_SIZE=4000000" \
        -e "SUPRA_MAX_UNCOMPRESSED_LOGS=5" \
        -e "SUPRA_MAX_LOG_FILES=20" \
        --net=host \
        -itd "$supra_docker_image"

    if [[ $? -eq 0 ]]; then
        echo "Docker container 'supra_mainnet_$ip' created successfully."
    else
        echo "Failed to create Docker container 'supra_mainnet_$ip'."
        return 1
    fi
}

create_smr_settings() {
    echo ""
    echo "CREATE SMR SETTINGS TOML FILE "
    echo ""
    local local_path="$1"
    local path_passed="${local_path}"
    local smr_settings_file="${path_passed}/smr_settings.toml"

    if [ -f "${smr_settings_file}" ]; then
        echo "smr_settings.toml already exists at ${path_passed}. Skipping creation."
        return 0
    fi

    # Create smr_settings.toml content
    cat <<EOF > "${smr_settings_file}"
    [instance]
    chain_id = 6
    epoch_duration_secs = 7200
    recurring_lockup_duration_secs = 14400
    voting_duration_secs = 7200
    is_testnet = true
    genesis_timestamp_microseconds = 1725840000000000

    [mempool]
    max_batch_delay_ms = 500
    max_batch_size_bytes = 500000
    sync_retry_delay_ms = 2000
    sync_retry_nodes = 3

    [moonshot]
    block_recency_bound_ms = 500
    halt_block_production_when_no_txs = false
    leader_elector = "FairSuccession"
    max_block_delay_ms = 2500
    max_payload_items_per_block = 100
    message_recency_bound_rounds = 20
    sync_retry_delay_ms = 1000
    timeout_delay_ms = 5000

    [node]
    connection_refresh_timeout_sec = 1
    resume = true
    root_ca_cert_path = "configs/ca_certificate.pem"
    rpc_access_port = 26000
    server_cert_path = "configs/server_supra_certificate.pem"
    server_private_key_path = "configs/server_supra_key.pem"

    [node.database_setup.dbs.chain_store.rocks_db]
    path = "configs/smr_storage"
    enable_pruning = true

    [node.database_setup.dbs.ledger.rocks_db]
    path = "configs/ledger_storage"

    [node.database_setup.prune_config]
    epochs_to_retain = 84
EOF
}

function parse_toml() {
    grep -w "$1" "$2" | cut -d'=' -f2- | tr -d ' "'
}

generate_and_activate_profile() {
    ip_address=$(parse_toml "ip_address" "$1")
    encoded_password=$(parse_toml "password" "$1")
    decoded_password=$(echo "$encoded_password" | openssl base64 -d -A)
    cd "$BASE_PATH"

expect << EOF
spawn docker exec -it supra_mainnet_$ip_address /supra/supra key generate-profile supra_mainnet_$ip_address
expect "password:" { send "$decoded_password\r" }
expect "password:" { send "$decoded_password\r" }
expect eof
EOF
    if [ $? -eq 0 ]; then
        echo ""
        echo "ACTIVATE PROFILE"
        echo ""

expect << EOF
spawn docker exec -it supra_mainnet_$ip_address /supra/supra key activate-profile supra_mainnet_$ip_address
expect "password:" { send "$decoded_password\r" }
expect eof
EOF
    else
        echo "Failed to generate profile. Exiting."
        exit 1
    fi
}

function generate_validator_identity() {
    echo " "
    echo "Generating validator identity"
    echo " " 

    ip_address=$(extract_ip "operator_config_mainnet.toml")
    local dns_name="$1"
    encoded_pswd=$(parse_toml "password" "$CONFIG_FILE")
    decoded_pswd=$(echo "$encoded_pswd" | openssl base64 -d -A)

    cd "$BASE_PATH" || { echo "Failed to change directory to $BASE_PATH"; exit 1; }

    if [ -n "$ip_address" ]; then
    expect << EOF
        spawn docker exec -it supra_mainnet_$ip_address /supra/supra key generate-validator-identity -s $ip_address:28000
        expect "password:" { send "$decoded_pswd\r" }
        expect eof
EOF
    elif [ -n "$dns_name" ]; then
    expect << EOF
        spawn docker exec -it supra_mainnet_$ip_address /supra/supra key generate-validator-identity -d $dns_name:28000
        expect "password:" { send "$decoded_pswd\r" }
        expect eof
EOF
    else
        echo 'No valid IP address or DNS name provided.'
        exit 1
    fi
    cd - > /dev/null
}

function generate_hashmap_phase_1() {
    
    if [[ $# -ne 1 ]]; then
        echo "Usage: generate_hashmap_phase_1 <output_file>"
        return 1
    fi

    local output_file=$1

    cd "$SCRIPT_EXECUTION_LOCATION" || { echo "Failed to change directory to $SCRIPT_EXECUTION_LOCATION"; exit 1; }

    declare -a files=(
        "smr_public_key.json"
        "smr_settings.toml"
        "validator_public_identity.toml"
    )

    declare -A hashmap
    for file in "${files[@]}"; do
        if [[ -f $file ]]; then
            hash=$(sha256sum "$file" | awk '{ print $1 }')
            hashmap["$file"]=$hash
        else
            echo "Skipping missing file: $file"
        fi
    done

    {
        echo "[hashes]"
        for key in "${!hashmap[@]}"; do
            echo "$key = \"${hashmap[$key]}\""
        done
    } > "$output_file"
    echo " "
    echo "Hashes have been written to $output_file"
}

function generate_hashmap_phase_2() {
    
    local hashmap_file="$1"
    local hash_toml="$2"

    if [ -z "$hashmap_file" ]; then
        echo "Error: Hashmap filename not provided."
        return 1
    fi

    cd "$SCRIPT_EXECUTION_LOCATION" || { echo "Failed to change directory to $SCRIPT_EXECUTION_LOCATION"; return 1; }

    declare -a files=(
        "$hash_toml"
        "supra_committees.json"
    )

    declare -A hashmap
    for file in "${files[@]}"; do
        if [[ -f $file ]]; then
            hash=$(sha256sum "$file" | awk '{ print $1 }')
            hashmap["$file"]=$hash
        else
            echo "Skipping missing file: $file"
        fi
    done

    {
        echo "[hashes]"
        for key in "${!hashmap[@]}"; do
            echo "$key = \"${hashmap[$key]}\""
        done
    } > "$hashmap_file"
    echo " "
    echo "Created: $hashmap_file"
}

function setup_repository_for_nodeOp() {
    echo ""
    cd "$BASE_PATH"

    local config_file="${BASE_PATH}/operator_config_mainnet.toml"
    local clone_folder="${BASE_PATH}/supra-nodeops-data"

    local ip_address
    ip_address=$(grep -oP '(?<=ip_address = ").*?(?=")' "$config_file")

    # Delete the clone folder if it already exists
    if [ -d "$clone_folder" ]; then
        rm -rf "$clone_folder"
        echo "Folder '$clone_folder' deleted."
    fi

    git clone https://github.com/Entropy-Foundation/supra-nodeops-data "$clone_folder"
    wait
    cd "$clone_folder" || exit
    
    # enable push data via ssh
    git remote set-url origin "$GITHUB_URL_SSH"
    echo "Check status"
    git remote -v
    
    git checkout master

    echo "Current branch: $(git rev-parse --abbrev-ref HEAD)"

    cd release_round7_data/operators || exit

    if [ ! -d "supra_mainnet_${ip_address}" ]; then
        mkdir "supra_mainnet_${ip_address}"
        echo "Folder 'supra_mainnet_${ip_address}' created successfully."
        IP_ADDRESS=$ip_address
    else
        echo "Folder 'supra_mainnet_${ip_address}' already exists."
    fi
}

copy_files_to_node_operator_folder() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: $0 source_directory destination_directory"
        exit 1
    fi

    local source_dir="$1"
    local destination_dir="$2"

    if [ ! -d "$source_dir" ]; then
        echo "Source directory '$source_dir' does not exist."
        exit 1
    fi

    if [ ! -d "$destination_dir" ]; then
        mkdir -p "$destination_dir"
    fi

    cp "$source_dir/smr_public_key.json" "$destination_dir"
    cp "$source_dir/validator_public_identity.toml" "$destination_dir"

    if [ $? -eq 0 ]; then
        echo "Files copied successfully."
    else
        echo "Failed to copy files."
    fi
}

check_phase_1_files() {
  local DIRECTORY=$1
  local FILES=(
    "hashmap_phase_1_previous.toml"
    "smr_public_key.json"
    "smr_settings.toml"
    "validator_public_identity.toml"
  )

  # Check each file
  for FILE in "${FILES[@]}"; do
    if [ ! -f "$DIRECTORY/$FILE" ]; then
      return 1
    fi
  done

  return 0
}

check_phase_2_files() {

  local DIRECTORY=$1
  local sig_file=$2
  local FILES=(
    "$sig_file"
    "supra_committees.json"
  )

  # Check each file
  for FILE in "${FILES[@]}"; do
    if [ ! -f "$DIRECTORY/$FILE" ]; then
      return 1
    fi
  done

  return 0
}

check_toml_hashes() {
    if [ "$#" -ne 2 ]; then
        echo "Error: Exactly two arguments are required."
        return 1
    fi

    file1="$1"
    file2="$2"
    if [ ! -f "$file1" ]; then
        echo "Error: File $file1 does not exist."
        return 1
    fi

    if [ ! -f "$file2" ]; then
        echo "Error: File $file2 does not exist."
        return 1
    fi

    hash1=$(sha256sum "$file1" | awk '{print $1}')
    hash2=$(sha256sum "$file2" | awk '{print $1}')

    if [ "$hash1" == "$hash2" ]; then
        echo "true"
    else
        echo "false"
    fi
}

delete_file() {
    if [ -f "$1" ]; then
        sudo rm "$1"
        echo "Deleted $1"
    else
        echo "$1 does not exist"
    fi
}

zip_and_delete_phase_2_files() {
    genesis_signature_files=(*_genesis_signature)
    supra_committees_file="supra_committees.json"
    hashmap_phase_2_previous_file="hashmap_phase_2_previous.toml"
    zip_file="phase_2_archived.zip"
    old_zip_file="old-phase_2_archived.zip"
    extracted_folder="extracted"
    supra_node_logs_folder="supra_node_logs"

    # Check if any _genesis_signature file is present
    if ls *_genesis_signature 1> /dev/null 2>&1; then
        files_to_zip=("${genesis_signature_files[@]}")
        
        if [ -f "$supra_committees_file" ]; then
            files_to_zip+=("$supra_committees_file")
        fi
        
        if [ -f "$hashmap_phase_2_previous_file" ]; then
            files_to_zip+=("$hashmap_phase_2_previous_file")
        fi

        if [ -d "$extracted_folder" ]; then
            files_to_zip+=("$extracted_folder")
        fi

        if [ -d "$supra_node_logs_folder" ]; then
            files_to_zip+=("$supra_node_logs_folder")
        fi

        if [ -f "$zip_file" ]; then
            mv "$zip_file" "$old_zip_file"
        fi
        
        if [ -f "$old_zip_file" ]; then
            files_to_zip+=("$old_zip_file")
        fi
        
        zip -r "$zip_file" "${files_to_zip[@]}"
        
        for file in "${files_to_zip[@]}"; do
            sudo rm -rf "$file"
        done

        echo "Files and folders have been archived and removed."
    else
        echo "No _genesis_signature files found."
    fi
}

zip_and_delete_phase_3_file() {
    hash_file_1=$1
    zip -r phase_3_archive.zip $hash_file_1 
    rm $hash_file_1
}

getValidRepoLink() {
    while true; do
        read -p "Please provide a GitHub repo link (.zip format): " repoLink

        # Check if the provided link ends with .zip
        if [[ $repoLink =~ \.zip$ ]]; then
            # Valid GitHub link in .zip format provided
            break
        else
            echo "Invalid GitHub repo link. Please make sure it's in .zip format."
        fi
    done

    # Return the valid repo link
    echo "$repoLink"
}

copy_signature_file_to_github() {
    local source_file="$1"
    local destination_path="$2"
    
    # Check if source file exists
    if [ -f "$source_file" ]; then
        # Copy the file to destination path
        cp "$source_file" "$destination_path"
        echo "File copied successfully."
    else
        echo "Source file does not exist."
    fi
}

validate_docker_image() {
    while true; do
        read -p "Please provide the docker image (must start with 'asia', contain 'validator-node', and have a 'v' tag): " image_response

        if [[ "$image_response" =~ ^asia.*validator-node.*:v[0-9]+\.* ]]; then
            echo "Valid Docker image provided: $image_response"
            SUPRA_DOCKER_IMAGE="$image_response"
            break
        else
            echo "Invalid Docker image format. Please provide a valid image starting with 'asia', containing 'validator-node', and having a 'v' tag."
        fi
    done
}

check_and_start_container() {
    local CONTAINER_NAME="$1"
    local container_exists=$(docker ps -a --format '{{.Names}}' | grep -w "$CONTAINER_NAME")
    if [ -z "$container_exists" ]; then
        echo "Container is not unavailable"
        return 1
    fi
    local container_running=$(docker ps --format '{{.Names}}' | grep -w "$CONTAINER_NAME")

    if [ -z "$container_running" ]; then
        echo "Container is not running. Starting the container..."
        docker start "$CONTAINER_NAME"
    else
        echo " ✔ Container is running."
    fi
}

function automated_validator_node_setup_and_configuration() {
   
    configure_operator
    validate_docker_image    
    create_supra_container "$SUPRA_DOCKER_IMAGE"
    create_smr_settings "$SCRIPT_EXECUTION_LOCATION"
    cd $SCRIPT_EXECUTION_LOCATION || { echo "Failed to change directory to $SCRIPT_EXECUTION_LOCATION"; exit 1; }
    generate_and_activate_profile "$CONFIG_FILE"

    # Prompt for either IP address or DNS name
    while true; do
        echo "Would you like to configure the validator node using:"
        echo "1. IP address"
        echo "2. DNS name"
        read -p "Enter your choice (1 or 2): " choice

        case $choice in
            1)
                # Prompt for IP address
                while true; do
                    IP_ADDRESS=$(extract_ip "operator_config_mainnet.toml") 
                    if [[ $IP_ADDRESS =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                        DNS_NAME=""  # Reset DNS if the user chooses IP
                        generate_validator_identity "$DNS_NAME"

                        break
                    else
                        echo "Invalid IP address. Please enter a valid IP address."
                    fi
                done
                break
                ;;
            2)
                # Prompt for DNS name
                while true; do
                    read -p "Enter the DNS name of the validator node: " DNS_NAME
                    if [[ -z "$DNS_NAME" ]]; then
                        echo "DNS name cannot be empty. Please enter a valid DNS name."
                    else
                        IP_ADDRESS=""  # Reset IP if the user chooses DNS
                        generate_validator_identity
                        break
                    fi
                done
                break
                ;;
            *)
                echo "Invalid choice. Please select 1 for IP address or 2 for DNS name."
                ;;
        esac
    done

    generate_hashmap_phase_1 hashmap_phase_1_previous.toml
    setup_repository_for_nodeOp $SCRIPT_EXECUTION_LOCATION
    copy_files_to_node_operator_folder $SCRIPT_EXECUTION_LOCATION $BASE_PATH/supra-nodeops-data/release_round7_data/operators/supra_mainnet_$ip_address 
    echo "_________________________________________________________________________________________________________________"
    echo ""
    echo "                                         ✔ Phase 1: Completed Successfully                                       "
    echo ""
    echo "1. Files are copied to supra-nodeops-data/release_round7_data/operators/supra_mainnet_$ip_address"
    echo "2. Please create a fork PR, and submit it to Supra Team"    
    echo "_________________________________________________________________________________________________________________"
    echo ""
    echo ""               
    exit 0
}

phase2_fresh_start() {
    local sig_file=$1
    config_file="$2"
    working_directory="$3"
    ip_address=$(parse_toml "ip_address" "$config_file")
    encoded_pswd=$(parse_toml "password" "$config_file")
    
    echo "Phase 2 fresh start"
    echo "## Make sure supra-nodeops-data repo is already there otherwise please clone first"
    
    validRepoLink=$(getValidRepoLink)
    
    echo "You provided a valid GitHub repo link: $validRepoLink"
    echo "build supra committee"

    docker exec -it supra_mainnet_$ip_address /supra/supra genesis build-supra-committee "$validRepoLink"
    echo "sign supra committee"
    
    # Execute supra genesis sign-supra-committee with expect script for password input
    expect << EOF
spawn docker exec -it supra_mainnet_$ip_address /supra/supra genesis sign-supra-committee
expect "password:" { send "$decoded_password\r" }
expect eof
EOF

    echo "Hashing signature and committee files "

    generate_hashmap_phase_2 "hashmap_phase_2_previous.toml" "$SCRIPT_EXECUTION_LOCATION/$sig_file"
    echo "clone signature files to github"

    destination_path="$BASE_PATH/supra-nodeops-data/release_round7_data/signatures"

    copy_signature_file_to_github "$SCRIPT_EXECUTION_LOCATION/$FILE_NAME" "$destination_path"

    echo "_________________________________________________________________________________________________________________"
    echo ""
    echo "                                         ✔ Phase 2: Completed Successfully                                       "
    echo ""
    echo "1. Signature file already copied to supra-nodeops-data/release_round7_data/signatures/"
    echo "2. Please copy $FILENAME to your forked repo and do git add, commit and push"    
    echo "_________________________________________________________________________________________________________________"
    echo ""
    echo ""   
    exit 0
}

zip_and_clean_phase_3_files() {
  # Define the file and zip names
  BLOB_FILE="genesis.blob"
  ZIP_FILE="phase_3_archived.zip"
  OLD_ZIP_FILE="old-phase_3_archived.zip"
  FILE_TO_REMOVE_1="genesis.blob"
  FILE_TO_REMOVE_2="hashmap_phase_1_latest.toml"
  FILE_TO_REMOVE_3="hashmap_phase_2_latest.toml"


  if [ -f "$BLOB_FILE" ]; then
    if [ -f "$ZIP_FILE" ]; then
      mv "$ZIP_FILE" "$OLD_ZIP_FILE"
      zip -r "$ZIP_FILE" "$OLD_ZIP_FILE"
      rm "$OLD_ZIP_FILE"
    fi

    zip -r "$ZIP_FILE" "$BLOB_FILE"
    sudo rm -rf "$FILE_TO_REMOVE_1" "$FILE_TO_REMOVE_2" "$FILE_TO_REMOVE_3"

  fi
}

start_node(){
    ip_address=$(extract_ip "operator_config_mainnet.toml")
    encoded_pswd=$(parse_toml "password" "$CONFIG_FILE")
    password=$(echo "$encoded_pswd" | openssl base64 -d -A)

    expect << EOF
        spawn docker exec -it supra_mainnet_$ip_address /supra/supra node smr run
        expect "password:" { send "$password\r" }
        expect eof
EOF
}

grafana_options(){

     while true; do
            echo "Please select the appropriate option for Grafana"
            echo "1. Select to Setup Grafana"
            echo "2. Select to Skip Grafana Setup"
            read -p "Enter your choice (1 or 2): " choice

            case $choice in
                1)
                    while true; do
                        echo "Adding Grafana dashboard..."
                        echo "Select your system type"
                        echo "1. Ubuntu/Debian Linux"
                        echo "2. Amazon Linux/Centos Linux"
                        read -p "Enter your system type: " prompt_user

                        if [ "$prompt_user" = "1" ]; then
                            wget -O nodeops-monitoring-telegraf.sh "$GRAFANA"
                            chmod +x nodeops-monitoring-telegraf.sh
                            sudo -E ./nodeops-monitoring-telegraf.sh
                        elif [ "$prompt_user" = "2" ]; then
                            wget -O nodeops-monitoring-telegraf-centos.sh "$GRAFANA_CENTOS"
                            chmod +x nodeops-monitoring-telegraf-centos.sh
                            sudo -E ./nodeops-monitoring-telegraf-centos.sh
                        else
                            echo "Invalid option selected. Please enter 1 for Ubuntu/Debian Linux or 2 for Amazon Linux/Centos Linux."
                        fi
                        break
                    done
                    break
                    ;;
                2)
                    while true; do
                        echo "Skip the Grafana Setup"
                        break
                    done
                    break
                    ;;
                *)
                    echo "Invalid choice. Please select 1 for grafana setup or 2 skip the grafana."
                    ;;
            esac
        done
    
}

start_supra_container(){
ip_address=$(grep 'ip_address' operator_config_mainnet.toml | awk -F'=' '{print $2}' | tr -d ' "')
echo "Starting supra container"
    if ! docker start supra_mainnet_$ip_address; then
        echo "Failed starting the Validator node container"
        exit 1
    else
        rm "$SCRIPT_EXECUTION_LOCATION/genesis_blob.zip"
        rm -rf "$SCRIPT_EXECUTION_LOCATION/genesis_blob"
        echo "Started the Validator Node container."
    fi
}

stop_supra_container(){
ip_address=$(grep 'ip_address' operator_config_mainnet.toml | awk -F'=' '{print $2}' | tr -d ' "')
echo "Stopping supra container"
if ! docker stop supra_mainnet_$ip_address; then
    echo "Failed to stop supra container. Exiting..."
fi
}

snapshot_download(){
if ! command -v unzip &> /dev/null; then
    if [ -f /etc/apt/sources.list ]; then
        package_manager="sudo apt install"
        $package_manager -y unzip
    elif [ -f /etc/yum.repos.d/ ]; then
        package_manager="sudo yum install"
        $package_manager -y unzip
    else
        echo "**WARNING: Could not identify package manager. Please install unzip manually."
        exit 1
    fi
else
    echo ""
fi 
rm -rf $SCRIPT_EXECUTION_LOCATION/ledger_storage $SCRIPT_EXECUTION_LOCATION/smr_storage/* $SCRIPT_EXECUTION_LOCATION/supra_node_logs $SCRIPT_EXECUTION_LOCATION/latest_snapshot.zip $SCRIPT_EXECUTION_LOCATION/snapshot

# Download snapshot 
echo "Downloading the latest snapshot......"
wget -O $SCRIPT_EXECUTION_LOCATION/latest_snapshot.zip https://testnet-snapshot.supra.com/snapshots/latest_snapshot.zip

# Unzip snapshot 
unzip $SCRIPT_EXECUTION_LOCATION/latest_snapshot.zip -d $SCRIPT_EXECUTION_LOCATION/

# Copy snapshot into smr_database
cp $SCRIPT_EXECUTION_LOCATION/snapshot/snapshot_*/store/* $SCRIPT_EXECUTION_LOCATION/smr_storage/
wget -O $SCRIPT_EXECUTION_LOCATION/genesis_blob.zip https://testnet-snapshot.supra.com/configs/genesis_blob.zip
unzip $SCRIPT_EXECUTION_LOCATION/genesis_blob.zip -d $SCRIPT_EXECUTION_LOCATION/
cp $SCRIPT_EXECUTION_LOCATION/genesis_blob/genesis.blob $SCRIPT_EXECUTION_LOCATION/
}

phase3_fresh_start() {

    config_file="$1"
    working_directory="$2"

    ip_address=$(parse_toml "ip_address" "$config_file")
    encoded_pswd=$(parse_toml "password" "$config_file")
    echo "Phase 3 fresh start"
   
    validRepo=$(getValidRepoLink)
    echo "You provided a valid GitHub repo link: $validRepo"
    docker exec -it supra_mainnet_$ip_address /supra/supra genesis refresh-repo "$validRepo"
   
    echo "Generate Genesis Blob"
    echo ""
    docker exec -it supra_mainnet_$ip_address /supra/supra genesis generate-genesis-blob
    echo "_________________________________________________________________________________________________________________"
    echo ""
    echo "                                         ✔ Phase 3: Completed                                                    "
    echo ""  Genesis.blob file is stored at $SCRIPT_EXECUTION_LOCATION/genesis.blob
    echo "_________________________________________________________________________________________________________________"
    echo ""
    echo ""   
    exit 0
}
 
update_supra_binaries(){
    # Parse ip_address from operator_config_mainnet.toml
    ip_address=$(grep 'ip_address' operator_config_mainnet.toml | awk -F'=' '{print $2}' | tr -d ' "')

    # Check if ip_address is set
    if [ -z "$ip_address" ]; then
        echo "IP address not found in config file."
        exit 1
    fi
    # Stop the Docker container if it's running
    echo "Stopping supra container"
    if ! docker stop supra_mainnet_$ip_address; then
        echo "Failed to stop supra container. Exiting..."
    fi
    echo "Supra container stopped"

    # Remove the Docker container
    echo "Removing supra container"
    if ! docker rm supra_mainnet_$ip_address; then
        echo "Failed to remove supra container. Exiting..."
    fi
    echo "Supra container removed"

    validate_docker_image

    # Remove the old Docker image
    echo "Deleting old docker image"
    if ! docker rmi $SUPRA_DOCKER_IMAGE; then
        echo "Failed to delete old Docker image. Exiting..."
    fi
    echo "Deleted the old Docker image"

    # Run the Docker container
    echo "Running new docker image"
    USER_ID=$(id -u)
    GROUP_ID=$(id -g)

    validate_docker_image

    if !     docker run --name "supra_mainnet_$ip_address" \
            -v $SCRIPT_EXECUTION_LOCATION:/supra/configs \
            --user "$USER_ID:$GROUP_ID" \
            -e "SUPRA_HOME=/supra/configs" \
            -e "SUPRA_LOG_DIR=/supra/configs/supra_node_logs" \
            -e "SUPRA_MAX_LOG_FILE_SIZE=4000000" \
            -e "SUPRA_MAX_UNCOMPRESSED_LOGS=5" \
            -e "SUPRA_MAX_LOG_FILES=20" \
            --net=host \
            -itd $SUPRA_DOCKER_IMAGE; then
        echo "Failed to run new Docker image. Exiting..."
        exit 1
    fi
    echo "New Docker image created"
}

start_supra_node() {
    local password=$1
    local ip_address=$2

    # Check if container is running
    if docker ps --filter "name=supra_mainnet_$ip_address" --format '{{.Names}}' | grep -q supra_mainnet_$ip_address; then

        # Prompt for either IP address or DNS name
        while true; do
            echo "Please select the appropriate option to start the node:"
            echo "1. Start your node within 4 hour window of network start"
            echo "2. Start your node after 4 hour window of the network start using snapshot"
            read -p "Enter your choice (1 or 2): " choice

            case $choice in
                1)
                    # Prompt for IP address
                    while true; do
                        start_node
                        break
                    done
                    break
                    ;;
                2)
                    # Prompt for DNS name
                    while true; do
                        snapshot_download
                        start_node
                        break
                    done
                    break
                    ;;
                *)
                    echo "Invalid choice. Please select 1 for node without snapshot or 2 using the snapshot."
                    ;;
            esac
        done
    else
        echo "Your container supra_mainnet_$ip_address is not running."
    fi
}

while true; do

    create_folder_and_files
    prerequisites
    echo ""
    display_questions
    echo ""
    read -p "Enter your choice: " choice

    case $choice in
        1)
            check_permissions "$SCRIPT_EXECUTION_LOCATION"
            archive_and_remove_phase_1_files

            if is_supra_running; then
                echo "-----------------------------------------------------------------"
                read -p "Do you want to remove a Docker container? (y/n): " confirm
                if [[ $confirm == [yY] ]]; then
                    remove_container_prompt 
                    automated_validator_node_setup_and_configuration
                else
                    automated_validator_node_setup_and_configuration
                    echo ""
                    echo "reached end of choice"
                fi
            else
            automated_validator_node_setup_and_configuration
            echo ""
            echo "Reached end of choice"
        fi

            
            ;;
        2)

            IP_ADDRESS=$(extract_ip "operator_config_mainnet.toml")
            FILE_NAME="$IP_ADDRESS:28000_genesis_signature.sig"
            CONFIG_FILE="$BASE_PATH/operator_config_mainnet.toml"
            enc_password=$(grep '^password' "$CONFIG_FILE" | awk -F' = ' '{print $2}' | tr -d '"')
            decoded_password=$(echo "$enc_password" | openssl base64 -d -A)
            
            check_and_start_container "supra_mainnet_$ip_address"
            echo "checking if phase 1 files are present"

            

            if (check_phase_1_files "$SCRIPT_EXECUTION_LOCATION"); then
                generate_hashmap_phase_1 "hashmap_phase_1_latest.toml"
                echo "Performing hash check for phase 1"
               
                resulted=$(check_toml_hashes "hashmap_phase_1_previous.toml" "hashmap_phase_1_latest.toml")
                   
                    echo ""
                    if [ "$resulted" == "true" ]; then
                        echo "✔ Success: verification of phase 1"
                    else
                        echo "Failure: phase 1 files were altered"
                        echo "Please : Start from Phase 1"
                        exit 0
                    fi
            else 
               echo "Phase 1 files are missing"
               echo "                                       Terminating Script                                      "
                exit 0
            fi
               echo "Checking phase 2 files are present"

            if (check_phase_2_files "$SCRIPT_EXECUTION_LOCATION" "$FILE_NAME"); then
                generate_hashmap_phase_2 "hashmap_phase_2_latest.toml" "$SCRIPT_EXECUTION_LOCATION/$sig_file"
                echo "Performing hash check for phase 2"
                
                result=$(check_toml_hashes "hashmap_phase_2_previous.toml" "hashmap_phase_2_latest.toml")
                    if [ "$result" == "true" ]; then
                        echo ""
                        echo "✔ Success: verification of phase 2"
                        echo ""
                        rm -rf hashmap_phase_2_latest.toml
                    else
                        echo " "
                        echo "Failure: phase 2 files were altered"
                    fi
            else 
                echo "Phase 2: Required files are not present"
                phase2_fresh_start "$FILE_NAME" $CONFIG_FILE $SCRIPT_EXECUTION_LOCATION

            fi
            read -p "Do you want to override phase 2 (Y/n) :: " decision

                if [[ $decision == [yY] ]]; then
                    echo ""
                    echo "Override Confirmed"
                    echo "Archiving Phase 2 Files"
                    zip_and_delete_phase_2_files
                    echo ""
                    phase2_fresh_start  "$FILE_NAME" $CONFIG_FILE $SCRIPT_EXECUTION_LOCATION
                else
                    echo "phase 2: override skipped"
                    echo ""
                    echo "terminating script"
                    echo ""
    
                    exit 0
                fi

            ;;
        3)
            echo ""
            IP_ADDRESS=$(extract_ip "operator_config_mainnet.toml") 
            FILE_NAME="$IP_ADDRESS:28000_genesis_signature.sig"
            CONFIG_FILE="$BASE_PATH/operator_config_mainnet.toml"
            enc_password=$(grep '^password' "$CONFIG_FILE" | awk -F' = ' '{print $2}' | tr -d '"')
            decoded_password=$(echo "$enc_password" | openssl base64 -d -A)

            check_and_start_container "supra_mainnet_$ip_address"

            if (check_phase_1_files "$SCRIPT_EXECUTION_LOCATION"); then
                generate_hashmap_phase_1 "Hashmap_phase_1_latest.toml"
                echo "Performing hash check for phase 1"

                resulted=$(check_toml_hashes "hashmap_phase_1_previous.toml" "hashmap_phase_1_latest.toml")
                    echo ""
                    echo ""
                    if [ "$resulted" == "true" ]; then
                        echo "✔ Success: Verification of phase 1"
                    else
                        echo "Failure: Hhase 1 files were altered"
                        echo "Please : Start from Phase 1"
                        exit 0
                    fi
            else 
                echo "Phase 1 : Files are missing"
                exit 0
            fi
                echo "Checking if phase 2 files are present"

            if (check_phase_2_files "$SCRIPT_EXECUTION_LOCATION" "$FILE_NAME"); then
                echo "Creating Hashmap again"
                generate_hashmap_phase_2 "hashmap_phase_2_latest.toml" "$SCRIPT_EXECUTION_LOCATION/$FILE_NAME"
                echo "Performing Hash Check for phase 2 "
                
                result=$(check_toml_hashes "hashmap_phase_2_previous.toml" "hashmap_phase_2_latest.toml")
                    echo "result :: $result"
                    if [ "$result" == "true" ]; then
                        echo " "
                        echo "✔ Success: Verification oF phase 2"
                        echo ""
                        echo ""
                        echo ""
                    else
                        echo " "
                        echo "Failure: Phase 2 files were altered"
                    fi
                
            else 
                echo "Phase 2: Required Files are not present"
                exit 0
            fi

               echo "Checking Phase 3 File is present"

            if [ -f genesis.blob ]; then
                echo "Genesis Blob is Present "
                echo ""
                echo ""

                read -p "Do you want to override phase 3 (Y/n) :: " decision

                if [[ $decision == [yY] ]]; then
                    echo ""
                    echo "Phase 3: Override Confirmed!"
                    echo "Archive Phase 3 Files"
                    zip_and_clean_phase_3_files "$SCRIPT_EXECUTION_LOCATION/genesis.blob"
                    echo ""
                    echo ""
                    phase3_fresh_start $CONFIG_FILE $SCRIPT_EXECUTION_LOCATION
                    echo " "
                else
                    echo "PHASE 3: Override Skipped"
                    echo ""
                    echo "terminating script"
                    echo ""
                    exit 0
                fi

            else
                echo "Genesis file is not present"
                phase3_fresh_start $CONFIG_FILE $SCRIPT_EXECUTION_LOCATION
            fi

            ;;
        
        4) 
            IP_ADDRESS=$(extract_ip "operator_config_mainnet.toml") 
            CONFIG_FILE="$BASE_PATH/operator_config_mainnet.toml"
            enc_password=$(grep '^password' "$CONFIG_FILE" | awk -F' = ' '{print $2}' | tr -d '"')
            decoded_password=$(echo "$enc_password" | openssl base64 -d -A)
            grafana_options
            echo "Starting the Node"
            start_supra_node "$decoded_password" "$IP_ADDRESS"
            ;;
        5)
            echo "Restart the node using snapshot"
            while true; do
                stop_supra_container
                snapshot_download
                start_supra_container
                start_node
                break
            done
            ;;
        6)
            echo "Update the binaries of network"
            while true; do
                update_supra_binaries
                break
            done
            ;;
        7)
            echo "Exit the script"
            exit 0
            ;;
        *)
            echo "Invalid choice. Please enter a number between 1 and 5."
            ;;

    esac
    echo ""
    # Pause before displaying the menu again
    read -p "Press Enter to continue..."
done