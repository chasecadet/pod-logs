#!/bin/bash

NAMESPACE="${NAMESPACE:-default}"
OUTPUT_DIR="${OUTPUT_DIR:-/logs}"
SINCE="${SINCE:-1h}"
HOSTNAMES=("jupyterhub.tiledb.example.com oauth2.tiledb.example.com api.tiledb.example.com console.tiledb.example.com") # Add your hostnames here
METRICS_SERVER_CHECK=true # Set to false if you don't want to check for the metrics server
LOG_FILE="${OUTPUT_DIR}/gather-logs.log"
ERROR_LOG_FILE="${OUTPUT_DIR}/error-log.log"
CLUSTER_STATE_FILE="${OUTPUT_DIR}/cluster-state.log"
LLM_PROMPT_FILE="${OUTPUT_DIR}/llm-prompt.txt"
MARIADB_HOST="${MARIADB_HOST:-localhost}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
MARIADB_USER="${MARIADB_USER:-root}"
MARIADB_PASSWORD="${MARIADB_PASSWORD:-password}"
MARIADB_DATABASE="${MARIADB_DATABASE:-tiledb_rest}"
MARIADB_TABLE="${MARIADB_TABLE:-arrays}"
MARIADB_USER_TO_CHECK="${MARIADB_USER_TO_CHECK:-tiledb_user}"

# Create the output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Redirect all output to the log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Function to check DNS resolution and ensure all hostnames resolve to the same IP
check_dns() {
  local resolved_ips=()
  for hostname in "${HOSTNAMES[@]}"; do
    ip=$(nslookup "$hostname" 2>/dev/null | grep 'Address:' | tail -n1 | awk '{print $2}')
    if [[ -n "$ip" ]]; then
      echo "Hostname $hostname resolves to IP $ip."
      resolved_ips+=("$ip")
    else
      echo "ERROR: Hostname $hostname could not be resolved."
    fi
  done

  # Check if all resolved IPs are the same
  unique_ips=($(echo "${resolved_ips[@]}" | tr ' ' '\n' | sort | uniq))
  if [[ ${#unique_ips[@]} -gt 1 ]]; then
    echo "ERROR: Not all hostnames resolve to the same IP. Resolved IPs: ${unique_ips[*]}"
  fi
}

# Function to check for the Metrics Server and ensure it resolves to the expected IP
check_metrics_server() {
  if METRICS_SERVER_IP=$(kubectl get --raw /apis/metrics.k8s.io/v1beta1 2>/dev/null | grep -oP '(?<=https:\/\/)[^\/]+' | head -n1); then
    echo "Metrics Server resolves to $METRICS_SERVER_IP."
    
    # Check if the Metrics Server resolves to the same IP as the DNS entries
    if [[ " ${resolved_ips[@]} " =~ " ${METRICS_SERVER_IP} " ]]; then
      echo "Metrics Server IP matches one of the resolved DNS IPs."
    else
      echo "ERROR: Metrics Server IP ($METRICS_SERVER_IP) does not match the resolved DNS IPs (${resolved_ips[*]})."
    fi
  else
    echo "ERROR: Metrics Server is not available."
  fi
}

# Function to check pods that are not ready and print their events
check_pod_readiness() {
  local not_ready_pods=()
  for pod in $(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running -o jsonpath='{.items[*].metadata.name}'); do
    not_ready_pods+=("$pod")
    echo "Pod $pod is not ready."
    echo "Events for pod $pod:"
    kubectl describe pod "$pod" -n "$NAMESPACE" | awk '/Events:/,/^$/ { if ($0 ~ /^ *$/) exit; print }'
    echo "----------------------------------------"
  done

  if [ ${#not_ready_pods[@]} -eq 0 ]; then
    echo "All pods are ready."
  fi
}

# Function to check user access and roles in MariaDB
check_mariadb_user_access() {
  echo "Checking MariaDB user access and roles..."

  # Connect to the MariaDB instance and check access
  ACCESS_QUERY="SHOW GRANTS FOR '${MARIADB_USER_TO_CHECK}'@'%';"
  ROLE_QUERY="SELECT grantee, role_name FROM information_schema.applicable_roles WHERE grantee='${MARIADB_USER_TO_CHECK}';"
  TABLE_ACCESS_QUERY="SELECT TABLE_NAME, PRIVILEGE_TYPE FROM information_schema.table_privileges WHERE GRANTEE=\"'${MARIADB_USER_TO_CHECK}'@'%'\" AND TABLE_NAME='${MARIADB_TABLE}';"

  mysql -h "$MARIADB_HOST" -P "$MARIADB_PORT" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "$ACCESS_QUERY" > "${OUTPUT_DIR}/mariadb_access.log" 2>&1
  mysql -h "$MARIADB_HOST" -P "$MARIADB_PORT" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "$ROLE_QUERY" >> "${OUTPUT_DIR}/mariadb_access.log" 2>&1
  mysql -h "$MARIADB_HOST" -P "$MARIADB_PORT" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "$TABLE_ACCESS_QUERY" >> "${OUTPUT_DIR}/mariadb_access.log" 2>&1

  echo "MariaDB access and roles check completed. Results are stored in ${OUTPUT_DIR}/mariadb_access.log"
}

# Function to check for an Ingress controller and related Ingress resources
check_ingress_resources() {
  echo "Checking for Ingress controller and resources..."

  # Check if an Ingress controller is present
  if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx > /dev/null 2>&1; then
    echo "Ingress controller is running in the $NAMESPACE namespace."
  else
    echo "ERROR: Ingress controller is not found in the $NAMESPACE namespace."
  fi

  # Check for Ingress resources associated with the specified hostnames
  for hostname in "${HOSTNAMES[@]}"; do
    if kubectl get ingress -n "$NAMESPACE" -o jsonpath="{.items[?(@.spec.rules[*].host=='$hostname')].metadata.name}" | grep -q .; then
      ingress_name=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath="{.items[?(@.spec.rules[*].host=='$hostname')].metadata.name}")
      echo "Ingress resource for $hostname found: $ingress_name"
    else
      echo "ERROR: No Ingress resource found for $hostname in the $NAMESPACE namespace."
    fi
  done
}

# Function to scan logs for errors
check_logs_for_errors() {
  echo "Scanning logs for errors..."
  grep -i "error\|failed\|exception" "${OUTPUT_DIR}"/*.log > "$ERROR_LOG_FILE"
  if [ -s "$ERROR_LOG_FILE" ]; then
    echo "Errors found in logs. Details are stored in $ERROR_LOG_FILE"
  else
    echo "No errors found in logs."
  fi
}

# Function to gather cluster-wide state information
gather_cluster_state() {
  echo "Gathering cluster-wide state information..."
  kubectl get all --all-namespaces > "$CLUSTER_STATE_FILE"
  kubectl describe nodes >> "$CLUSTER_STATE_FILE"
  kubectl get events --all-namespaces >> "$CLUSTER_STATE_FILE"
  echo "Cluster state information gathered and stored in $CLUSTER_STATE_FILE"
}

# Function to generate a prompt for the LLM
generate_llm_prompt() {
  echo "Generating LLM prompt based on gathered data..."
  echo "Cluster State Overview:" > "$LLM_PROMPT_FILE"
  tail -n 20 "$CLUSTER_STATE_FILE" >> "$LLM_PROMPT_FILE"
  
  if [ -s "$ERROR_LOG_FILE" ]; then
    echo "" >> "$LLM_PROMPT_FILE"
    echo "Errors Detected:" >> "$LLM_PROMPT_FILE"
    tail -n 10 "$ERROR_LOG_FILE" >> "$LLM_PROMPT_FILE"
  else
    echo "" >> "$LLM_PROMPT_FILE"
    echo "No significant errors detected in the logs." >> "$LLM_PROMPT_FILE"
  fi

  echo "" >> "$LLM_PROMPT_FILE"
  echo "Suggested areas to investigate:" >> "$LLM_PROMPT_FILE"
  echo "1. Review the pods that are not ready." >> "$LLM_PROMPT_FILE"
  echo "2. Examine the Ingress resources and their configurations." >> "$LLM_PROMPT_FILE"
  echo "3. Check DNS resolution consistency and Metrics Server availability." >> "$LLM_PROMPT_FILE"
  
  echo "LLM prompt generated and stored in $LLM_PROMPT_FILE"
}

# Execute functions in sequence
check_dns
check_metrics_server
check_pod_readiness
check_mariadb_user
