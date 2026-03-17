#!/bin/bash
# References:
# OCI CLI docs: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm
# OCI Resource Manager jobs: https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Tasks/jobs.htm
# Telegram Bot API sendMessage: https://core.telegram.org/bots/api#sendmessage

export SUPPRESS_LABEL_WARNING=True

STACK_ID="your-stack-ocid-here"
LOGFILE="oracle_automation_v2.log"
COMPARTMENT_ID="your_compartment_id"
REGION="Unknown Region"

# Retry and rate-limit tuning
BASE_WAIT=50
MAX_WAIT=600
OCI_MAX_RETRIES=8
OCI_BASE_DELAY=12
OCI_MAX_DELAY=180
JOB_POLL_WAIT=20
TELEGRAM_RATE_LIMIT_COOLDOWN=900

# Runtime state
LAST_PLAN_RATE_LIMIT_ALERT_TS=0
LAST_APPLY_RATE_LIMIT_ALERT_TS=0
ATTEMPT=0
CONSECUTIVE_RETRIES=0

# Telegram Configuration
TELEGRAM_BOT_TOKEN="your-bot-token-here"
TELEGRAM_CHAT_ID="your-chat-id-here"

# --- Helpers ---
send_telegram() {
    local message="$1"

    if [ "${TELEGRAM_BOT_TOKEN}" = "your-bot-token-here" ] || [ "${TELEGRAM_CHAT_ID}" = "your-chat-id-here" ]; then
        return 0
    fi

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="HTML" > /dev/null 2>&1
}

log_line() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | tee -a ${LOGFILE}
}

is_transient_error() {
    local payload="$1"
    local rc="${2:-1}"

    # Successful commands should not be treated as transient failures.
    if [ "${rc}" -eq 0 ]; then
        return 1
    fi

    if echo "${payload}" | grep -qiE 'TooManyRequests|TransientServiceError|ServiceUnavailable|InternalServerError|RequestTimeout|ConnectionError|connection reset|temporarily unavailable|timed out|try again|status[[:space:]]*[:=][[:space:]]*429|HTTP[[:space:]]*429|"status"[[:space:]]*:[[:space:]]*429|"code"[[:space:]]*:[[:space:]]*"TooManyRequests"'; then
        return 0
    fi

    return 1
}

send_rate_limit_alert() {
    local scope="$1"
    local now_ts
    now_ts=$(date +%s)

    if [ "${scope}" = "PLAN" ]; then
        if [ $((now_ts - LAST_PLAN_RATE_LIMIT_ALERT_TS)) -lt ${TELEGRAM_RATE_LIMIT_COOLDOWN} ]; then
            return 0
        fi
        LAST_PLAN_RATE_LIMIT_ALERT_TS=${now_ts}
        send_telegram "⚠️ <b>PLAN Rate Limited</b>%0A%0AResource Manager API throttled your request.%0AThe script will back off and retry automatically."
        return 0
    fi

    if [ "${scope}" = "APPLY" ]; then
        if [ $((now_ts - LAST_APPLY_RATE_LIMIT_ALERT_TS)) -lt ${TELEGRAM_RATE_LIMIT_COOLDOWN} ]; then
            return 0
        fi
        LAST_APPLY_RATE_LIMIT_ALERT_TS=${now_ts}
        send_telegram "⚠️ <b>APPLY Rate Limited</b>%0A%0AResource Manager API throttled your APPLY request.%0AThe script will back off and retry automatically."
    fi
}

calc_backoff() {
    local attempt="$1"
    local base_delay="$2"
    local max_delay="$3"
    local delay=$((base_delay * (2 ** (attempt - 1))))
    local jitter=$((RANDOM % 6))

    if [ ${delay} -gt ${max_delay} ]; then
        delay=${max_delay}
    fi

    echo $((delay + jitter))
}

oci_with_retry() {
    local action_name="$1"
    shift

    local attempt=1
    local output
    local rc

    while true; do
        output=$("$@" 2>&1)
        rc=$?

        if [ ${rc} -eq 0 ]; then
            echo "${output}"
            return 0
        fi

        if ! is_transient_error "${output}" "${rc}"; then
            echo "${output}"
            return 1
        fi

        if [ ${attempt} -ge ${OCI_MAX_RETRIES} ]; then
            log_line "${action_name} failed after ${attempt} retries due to repeated transient errors."
            echo "${output}"
            return 1
        fi

        local sleep_for
        sleep_for=$(calc_backoff ${attempt} ${OCI_BASE_DELAY} ${OCI_MAX_DELAY})
        log_line "${action_name} hit API throttling/transient error. Retry ${attempt}/${OCI_MAX_RETRIES} in ${sleep_for}s."
        sleep ${sleep_for}
        attempt=$((attempt + 1))
    done
}

get_configured_region() {
    local configured_region
    configured_region=$(oci setup config get region --raw-output 2>/dev/null)

    if [ -n "${configured_region}" ]; then
        echo "${configured_region}"
        return 0
    fi

    configured_region=$(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output 2>/dev/null)
    if [ -n "${configured_region}" ]; then
        echo "${configured_region}"
        return 0
    fi

    echo "Unknown Region"
}

resolve_stack_id() {
    if [[ -n "${STACK_ID}" && "${STACK_ID}" != "your-stack-ocid-here" ]]; then
        return 0
    fi

    log_line "No STACK_ID provided. Trying auto-discovery like the basic script..."

    COMPARTMENT_ID=$(oci iam compartment list --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)
    if [[ ! "${COMPARTMENT_ID}" =~ ^ocid1\.compartment\. ]]; then
        COMPARTMENT_ID=$(oci iam compartment list --query 'data[0].id' --raw-output 2>/dev/null)
    fi

    if [[ ! "${COMPARTMENT_ID}" =~ ^ocid1\.compartment\. ]]; then
        log_line "Auto-discovery failed: could not determine COMPARTMENT_ID."
        return 1
    fi

    STACK_ID=$(oci resource-manager stack list --compartment-id "${COMPARTMENT_ID}" --query 'data[0].id' --raw-output 2>/dev/null)
    if [[ ! "${STACK_ID}" =~ ^ocid1\. ]]; then
        log_line "Auto-discovery failed: could not determine STACK_ID."
        return 1
    fi

    log_line "Auto-discovered STACK_ID: ${STACK_ID}"
    return 0
}

verify_prerequisites() {
    local missing=0

    for bin in oci jq curl; do
        if ! command -v "${bin}" > /dev/null 2>&1; then
            log_line "Missing dependency: ${bin}"
            missing=1
        fi
    done

    if [ ${missing} -ne 0 ]; then
        send_telegram "❌ <b>Dependency Error</b>%0A%0AInstall required tools: oci, jq, curl"
        return 1
    fi

    return 0
}

handle_stop_signal() {
    log_line "Received stop signal. Exiting cleanly."
    trap - EXIT
    exit 0
}

# Function to handle script exit/crash
cleanup() {
    local exit_code=$?
    if [ ${exit_code} -eq 0 ] || [ ${exit_code} -eq 130 ] || [ ${exit_code} -eq 143 ]; then
        return 0
    fi

    if [ $exit_code -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Script crashed with exit code: ${exit_code}" | tee -a ${LOGFILE}
        send_telegram "⚠️ <b>Script Crashed!</b>%0A%0A❌ Oracle A1 automation stopped unexpectedly%0A%0A🔢 Exit Code: ${exit_code}%0A📅 Time: $(date '+%Y-%m-%d %H:%M:%S')%0A%0ACheck the logs and restart if needed."
    fi
}

# Set traps to catch script exits and stop signals
trap cleanup EXIT
trap handle_stop_signal INT TERM

if ! verify_prerequisites; then
    exit 1
fi

REGION=$(get_configured_region)

if ! resolve_stack_id; then
    log_line "Please set a valid STACK_ID manually in this script and rerun."
    send_telegram "❌ <b>Stack Resolution Failed</b>%0A%0AAuto-discovery could not find a stack.%0ASet STACK_ID manually and rerun."
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Using Stack ID: ${STACK_ID}" | tee -a ${LOGFILE}
echo "$(date '+%Y-%m-%d %H:%M:%S') - Region: ${REGION}" | tee -a ${LOGFILE}
echo | tee -a ${LOGFILE}

# Send startup notification with region info
send_telegram "🤖 <b>${REGION} A1 Snipe Started</b>%0A%0A✅ Script is now running and will notify you when A1.Flex instance is created successfully!%0A%0A📅 Started: $(date '+%Y-%m-%d %H:%M:%S')"

function plan_job() {
    local job_id
    local job
    local status
    local old_status
    local error_msg

    log_line "Starting PLAN job..."
    
    # Check if OCI CLI is working
    if ! oci --version &> /dev/null; then
        echo "ERROR: OCI CLI not found or not configured properly" | tee -a ${LOGFILE}
        send_telegram "❌ <b>Configuration Error</b>%0A%0AOCI CLI not found or not working.%0APlease check your installation."
        return 1
    fi
    
    # Create PLAN job
    job_id=$(oci_with_retry "PLAN create_job" oci resource-manager job create --stack-id ${STACK_ID} --operation PLAN --query "data.id" --raw-output)
    
    # Check if job creation failed
    if [[ ${job_id} == *"ServiceError"* ]] || [[ ! ${job_id} =~ ^ocid1\. ]]; then
        echo "ERROR: Failed to create PLAN job: ${job_id}" | tee -a ${LOGFILE}
        if is_transient_error "${job_id}"; then
            send_rate_limit_alert "PLAN"
        else
            send_telegram "❌ <b>PLAN Job Creation Failed</b>%0A%0AError: ${job_id:0:200}%0A%0ACheck your Stack ID and permissions."
        fi
        return 1
    fi
    
    echo "Created 'PLAN' job with ID: '${job_id}'" | tee -a ${LOGFILE}
    echo -n "Status for 'PLAN' job:" | tee -a ${LOGFILE}

    while true; do
        old_status=${status}
        job=$(oci_with_retry "PLAN get_job" oci resource-manager job get --job-id ${job_id})
        
        # Check for API errors
        if [[ ${job} == *"ServiceError"* ]]; then
            echo -e "\nERROR: Failed to get job status" | tee -a ${LOGFILE}
            sleep ${JOB_POLL_WAIT}
            continue
        fi
        
        status=$(echo ${job} | jq -r '.data."lifecycle-state"')
        WAIT=10
        for i in $(seq 1 ${WAIT}); do
            if [ "${status}" == "${old_status}" ]; then
                echo -n "." | tee -a ${LOGFILE}
            else
                echo -n " ${status}" | tee -a ${LOGFILE}
                break
            fi
            sleep 1
        done
        if [ "${status}" == "SUCCEEDED" ]; then
            echo -e "\n" | tee -a ${LOGFILE}
            break
        elif [ "${status}" == "FAILED" ]; then
            echo -e "\nThe 'PLAN' job failed. Error message:" | tee -a ${LOGFILE}
            error_msg=$(echo ${job} | jq -r '.data."failure-details".message')
            echo ${error_msg} | tee -a ${LOGFILE}
            if is_transient_error "${error_msg}"; then
                log_line "PLAN failed with transient error, will retry from main loop."
                return 1
            fi
            send_telegram "⚠️ <b>PLAN Job Failed</b>%0A%0AError: ${error_msg:0:200}%0A%0ACheck your Terraform configuration."
            return 1
        fi
        sleep ${JOB_POLL_WAIT}
    done

    return 0
}

function apply_job() {
    local job_id
    local job
    local status
    local old_status
    local error_msg
    local detailed_error
    local instance_ip

    log_line "Starting APPLY job..."
    
    job_id=$(oci_with_retry "APPLY create_job" oci resource-manager job create --stack-id ${STACK_ID} --operation APPLY --apply-job-plan-resolution "{\"isAutoApproved\":true}" --query "data.id" --raw-output)
    
    # Check if job creation failed
    if [[ ${job_id} == *"ServiceError"* ]] || [[ ! ${job_id} =~ ^ocid1\. ]]; then
        echo "ERROR: Failed to create APPLY job: ${job_id}" | tee -a ${LOGFILE}
        if is_transient_error "${job_id}"; then
            send_rate_limit_alert "APPLY"
        fi
        return 1
    fi
    
    echo "Created 'APPLY' job with ID: '${job_id}'" | tee -a ${LOGFILE}
    echo -n "Status for 'APPLY' job:" | tee -a ${LOGFILE}

    while true; do
        old_status=${status}
        job=$(oci_with_retry "APPLY get_job" oci resource-manager job get --job-id ${job_id})
        
        # Check for API errors
        if [[ ${job} == *"ServiceError"* ]]; then
            echo -e "\nERROR: Failed to get job status" | tee -a ${LOGFILE}
            sleep ${JOB_POLL_WAIT}
            continue
        fi
        
        status=$(echo ${job} | jq -r '.data."lifecycle-state"')
        WAIT=10
        for i in $(seq 1 ${WAIT}); do
            if [ "${status}" == "${old_status}" ]; then
                echo -n "." | tee -a ${LOGFILE}
            else
                echo -n " ${status}" | tee -a ${LOGFILE}
                break
            fi
            sleep 1
        done
        if [ "${status}" == "SUCCEEDED" ]; then
            echo -e "\nThe 'APPLY' job succeeded. Exiting." | tee -a ${LOGFILE}
            
            # Get instance details if possible
            instance_ip=$(oci resource-manager job get-job-tf-state --job-id ${job_id} --query 'data' --raw-output 2>/dev/null | grep -oP '"public_ip":\s*"\K[^"]+' | head -1)
            
            # Send SUCCESS notification to Telegram
            if [ -n "${instance_ip}" ]; then
                send_telegram "🎉 <b>SUCCESS!</b> 🎉%0A%0A✅ Your Oracle Cloud A1.Flex instance has been created successfully!%0A%0A🌐 Public IP: ${instance_ip}%0A📅 Date: $(date '+%Y-%m-%d %H:%M:%S')%0A🆔 Job ID: ${job_id}%0A%0ASSH Command:%0A<code>ssh ubuntu@${instance_ip}</code>"
            else
                send_telegram "🎉 <b>SUCCESS!</b> 🎉%0A%0A✅ Your Oracle Cloud A1.Flex instance has been created successfully!%0A%0A📅 Date: $(date '+%Y-%m-%d %H:%M:%S')%0A🆔 Job ID: ${job_id}%0A%0ACheck your OCI Console to access your new instance!"
            fi
            
            # Disable trap before successful exit
            trap - EXIT
            exit 0
        elif [ "${status}" == "FAILED" ]; then
            echo -e "\nThe 'APPLY' job failed. Error message:" | tee -a ${LOGFILE}
            error_msg=$(echo ${job} | jq -r '.data."failure-details".message')
            echo ${error_msg} | tee -a ${LOGFILE}
            echo -e "\nLogged error:" | tee -a ${LOGFILE}
            detailed_error=$(oci resource-manager job get-job-logs-content --job-id ${job_id} --query 'data' --raw-output 2>/dev/null | grep "Error:" | head -3)
            echo ${detailed_error} | tee -a ${LOGFILE}
            
            # Check if it's a capacity error
            if [[ ${error_msg} == *"capacity"* ]] || [[ ${error_msg} == *"Out of host capacity"* ]] || [[ ${detailed_error} == *"capacity"* ]]; then
                echo -e "\nCapacity issue detected - will retry" | tee -a ${LOGFILE}
            else
                # Send notification for non-capacity errors
                send_telegram "⚠️ <b>Unexpected Error</b>%0A%0A${error_msg:0:200}%0A%0ARetrying..."
            fi
            
            echo -e "\nRetrying..." | tee -a ${LOGFILE}
            return 1
        fi
        sleep ${JOB_POLL_WAIT}
    done
}

main_retry_wait() {
    local retries="$1"
    local wait_time=$((BASE_WAIT * (2 ** retries)))
    local jitter=$((RANDOM % 10))

    if [ ${wait_time} -gt ${MAX_WAIT} ]; then
        wait_time=${MAX_WAIT}
    fi

    echo $((wait_time + jitter))
}

while true; do
    ATTEMPT=$((ATTEMPT + 1))
    log_line "Attempt #${ATTEMPT}"
    
    # Send periodic status update every 100 attempts
    if [ $((ATTEMPT % 100)) -eq 0 ]; then
        send_telegram "ℹ️ <b>Still Running</b>%0A%0A🔄 Attempt #${ATTEMPT}%0A⏰ Running since startup%0A%0AScript is still trying to get your A1 instance!"
    fi
    
    if ! plan_job; then
        CONSECUTIVE_RETRIES=$((CONSECUTIVE_RETRIES + 1))
        WAIT_FOR=$(main_retry_wait ${CONSECUTIVE_RETRIES})
        log_line "PLAN was not successful. Backing off for ${WAIT_FOR}s before retrying."
        sleep ${WAIT_FOR}
        log_line "Retrying..."
        continue
    fi

    if ! apply_job; then
        CONSECUTIVE_RETRIES=$((CONSECUTIVE_RETRIES + 1))
        WAIT_FOR=$(main_retry_wait ${CONSECUTIVE_RETRIES})
        log_line "APPLY was not successful. Backing off for ${WAIT_FOR}s before retrying."
        sleep ${WAIT_FOR}
        log_line "Retrying..."
        continue
    fi

    CONSECUTIVE_RETRIES=0
done
