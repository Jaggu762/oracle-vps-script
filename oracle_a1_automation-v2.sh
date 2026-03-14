#!/bin/bash

export SUPPRESS_LABEL_WARNING=True

STACK_ID="your-stack-ocid-here"
LOGFILE="oracle_automation_v2.log"

# Telegram Configuration
TELEGRAM_BOT_TOKEN="your-bot-token-here"
TELEGRAM_CHAT_ID="your-chat-id-here"

# Get region from OCI config for personalized messages
REGION=$(oci iam region list --query "data[0].name" --raw-output 2>/dev/null || echo "Unknown Region")

# Function to send Telegram message
send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="HTML" > /dev/null 2>&1
}

# Function to handle script exit/crash
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Script crashed with exit code: ${exit_code}" | tee -a ${LOGFILE}
        send_telegram "⚠️ <b>Script Crashed!</b>%0A%0A❌ Oracle A1 automation stopped unexpectedly%0A%0A🔢 Exit Code: ${exit_code}%0A📅 Time: $(date '+%Y-%m-%d %H:%M:%S')%0A%0ACheck the logs and restart if needed."
    fi
}

# Set trap to catch script exits
trap cleanup EXIT

echo "$(date '+%Y-%m-%d %H:%M:%S') - Using Stack ID: ${STACK_ID}" | tee -a ${LOGFILE}
echo "$(date '+%Y-%m-%d %H:%M:%S') - Region: ${REGION}" | tee -a ${LOGFILE}
echo | tee -a ${LOGFILE}

# Send startup notification with region info
send_telegram "🤖 <b>${REGION} A1 Snipe Started</b>%0A%0A✅ Script is now running and will notify you when A1.Flex instance is created successfully!%0A%0A📅 Started: $(date '+%Y-%m-%d %H:%M:%S')"

function plan_job() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting PLAN job..." | tee -a ${LOGFILE}
    
    # Check if OCI CLI is working
    if ! oci --version &> /dev/null; then
        echo "ERROR: OCI CLI not found or not configured properly" | tee -a ${LOGFILE}
        send_telegram "❌ <b>Configuration Error</b>%0A%0AOCI CLI not found or not working.%0APlease check your installation."
        exit 1
    fi
    
    # Create PLAN job
    JOB_ID=$(oci resource-manager job create --stack-id ${STACK_ID} --operation PLAN --query "data.id" --raw-output 2>&1)
    
    # Check if job creation failed
    if [[ $JOB_ID == *"ServiceError"* ]] || [[ ! $JOB_ID =~ ^ocid1\. ]]; then
        echo "ERROR: Failed to create PLAN job: ${JOB_ID}" | tee -a ${LOGFILE}
        send_telegram "❌ <b>PLAN Job Creation Failed</b>%0A%0AError: ${JOB_ID:0:200}%0A%0ACheck your Stack ID and permissions."
        exit 1
    fi
    
    echo "Created 'PLAN' job with ID: '${JOB_ID}'" | tee -a ${LOGFILE}
    echo -n "Status for 'PLAN' job:" | tee -a ${LOGFILE}

    while true; do
        OSTATUS=${STATUS}
        JOB=$(oci resource-manager job get --job-id ${JOB_ID} 2>&1)
        
        # Check for API errors
        if [[ $JOB == *"ServiceError"* ]]; then
            echo -e "\nERROR: Failed to get job status" | tee -a ${LOGFILE}
            send_telegram "❌ <b>API Error</b>%0A%0ACouldn't retrieve job status.%0ARetrying..."
            sleep 10
            continue
        fi
        
        STATUS=$(echo ${JOB} | jq -r '.data."lifecycle-state"')
        WAIT=10
        for i in $(seq 1 ${WAIT}); do
            if [ "${STATUS}" == "${OSTATUS}" ]; then
                echo -n "." | tee -a ${LOGFILE}
            else
                echo -n " ${STATUS}" | tee -a ${LOGFILE}
                break
            fi
            sleep 1
        done
        if [ "${STATUS}" == "SUCCEEDED" ]; then
            echo -e "\n" | tee -a ${LOGFILE}
            break
        elif [ "${STATUS}" == "FAILED" ]; then
            echo -e "\nThe 'PLAN' job failed. Error message:" | tee -a ${LOGFILE}
            ERROR_MSG=$(echo ${JOB} | jq -r '.data."failure-details".message')
            echo ${ERROR_MSG} | tee -a ${LOGFILE}
            send_telegram "⚠️ <b>PLAN Job Failed</b>%0A%0AError: ${ERROR_MSG:0:200}%0A%0ACheck your Terraform configuration."
            exit 1
        fi
        sleep 5
    done
}

function apply_job() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting APPLY job..." | tee -a ${LOGFILE}
    
    JOB_ID=$(oci resource-manager job create --stack-id ${STACK_ID} --operation APPLY --apply-job-plan-resolution "{\"isAutoApproved\":true}" --query "data.id" --raw-output 2>&1)
    
    # Check if job creation failed
    if [[ $JOB_ID == *"ServiceError"* ]] || [[ ! $JOB_ID =~ ^ocid1\. ]]; then
        echo "ERROR: Failed to create APPLY job: ${JOB_ID}" | tee -a ${LOGFILE}
        return 1
    fi
    
    echo "Created 'APPLY' job with ID: '${JOB_ID}'" | tee -a ${LOGFILE}
    echo -n "Status for 'APPLY' job:" | tee -a ${LOGFILE}

    while true; do
        OSTATUS=${STATUS}
        JOB=$(oci resource-manager job get --job-id ${JOB_ID} 2>&1)
        
        # Check for API errors
        if [[ $JOB == *"ServiceError"* ]]; then
            echo -e "\nERROR: Failed to get job status" | tee -a ${LOGFILE}
            sleep 10
            continue
        fi
        
        STATUS=$(echo ${JOB} | jq -r '.data."lifecycle-state"')
        WAIT=10
        for i in $(seq 1 ${WAIT}); do
            if [ "${STATUS}" == "${OSTATUS}" ]; then
                echo -n "." | tee -a ${LOGFILE}
            else
                echo -n " ${STATUS}" | tee -a ${LOGFILE}
                break
            fi
            sleep 1
        done
        if [ "${STATUS}" == "SUCCEEDED" ]; then
            echo -e "\nThe 'APPLY' job succeeded. Exiting." | tee -a ${LOGFILE}
            
            # Get instance details if possible
            INSTANCE_IP=$(oci resource-manager job get-job-tf-state --job-id ${JOB_ID} --query 'data' --raw-output 2>/dev/null | grep -oP '"public_ip":\s*"\K[^"]+' | head -1)
            
            # Send SUCCESS notification to Telegram
            if [ -n "$INSTANCE_IP" ]; then
                send_telegram "🎉 <b>SUCCESS!</b> 🎉%0A%0A✅ Your Oracle Cloud A1.Flex instance has been created successfully!%0A%0A🌐 Public IP: ${INSTANCE_IP}%0A📅 Date: $(date '+%Y-%m-%d %H:%M:%S')%0A🆔 Job ID: ${JOB_ID}%0A%0ASSH Command:%0A<code>ssh ubuntu@${INSTANCE_IP}</code>"
            else
                send_telegram "🎉 <b>SUCCESS!</b> 🎉%0A%0A✅ Your Oracle Cloud A1.Flex instance has been created successfully!%0A%0A📅 Date: $(date '+%Y-%m-%d %H:%M:%S')%0A🆔 Job ID: ${JOB_ID}%0A%0ACheck your OCI Console to access your new instance!"
            fi
            
            # Disable trap before successful exit
            trap - EXIT
            exit 0
        elif [ "${STATUS}" == "FAILED" ]; then
            echo -e "\nThe 'APPLY' job failed. Error message:" | tee -a ${LOGFILE}
            ERROR_MSG=$(echo ${JOB} | jq -r '.data."failure-details".message')
            echo ${ERROR_MSG} | tee -a ${LOGFILE}
            echo -e "\nLogged error:" | tee -a ${LOGFILE}
            DETAILED_ERROR=$(oci resource-manager job get-job-logs-content --job-id ${JOB_ID} --query 'data' --raw-output 2>/dev/null | grep "Error:" | head -3)
            echo ${DETAILED_ERROR} | tee -a ${LOGFILE}
            
            # Check if it's a capacity error
            if [[ $ERROR_MSG == *"capacity"* ]] || [[ $ERROR_MSG == *"Out of host capacity"* ]] || [[ $DETAILED_ERROR == *"capacity"* ]]; then
                echo -e "\nCapacity issue detected - will retry" | tee -a ${LOGFILE}
            else
                # Send notification for non-capacity errors
                send_telegram "⚠️ <b>Unexpected Error</b>%0A%0A${ERROR_MSG:0:200}%0A%0ARetrying..."
            fi
            
            echo -e "\nRetrying..." | tee -a ${LOGFILE}
            return 1
        fi
        sleep 5
    done
}

# Main loop
WAIT=35
ATTEMPT=0
while true; do
    ATTEMPT=$((ATTEMPT + 1))
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Attempt #${ATTEMPT}" | tee -a ${LOGFILE}
    
    # Send periodic status update every 100 attempts
    if [ $((ATTEMPT % 100)) -eq 0 ]; then
        send_telegram "ℹ️ <b>Still Running</b>%0A%0A🔄 Attempt #${ATTEMPT}%0A⏰ Running since startup%0A%0AScript is still trying to get your A1 instance!"
    fi
    
    plan_job
    if ! apply_job; then
        sleep ${WAIT}
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Retrying..." | tee -a ${LOGFILE}
        continue
    fi
done
