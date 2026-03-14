#!/bin/bash

export SUPPRESS_LABEL_WARNING=True

STACK_ID="your-stack-ocid-here"
LOGFILE="oracle_automation_v2.log"

# Telegram Configuration
TELEGRAM_BOT_TOKEN="your-bot-token-here"
TELEGRAM_CHAT_ID="your-chat-id-here"

# Function to send Telegram message
send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="HTML" > /dev/null 2>&1
}

echo "$(date '+%Y-%m-%d %H:%M:%S') - Using Stack ID: ${STACK_ID}" | tee -a ${LOGFILE}
echo | tee -a ${LOGFILE}

# Send startup notification
send_telegram "🤖 <b>Oracle A1 Automation Started</b>%0A%0AScript is now running and will notify you when A1.Flex instance is created successfully!"

function plan_job() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting PLAN job..." | tee -a ${LOGFILE}
    JOB_ID=$(oci resource-manager job create --stack-id ${STACK_ID} --operation PLAN --query "data.id" --raw-output)
    echo "Created 'PLAN' job with ID: '${JOB_ID}'" | tee -a ${LOGFILE}
    echo -n "Status for 'PLAN' job:" | tee -a ${LOGFILE}

    while true; do
        OSTATUS=${STATUS}
        JOB=$(oci resource-manager job get --job-id ${JOB_ID})
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
            echo $(echo ${JOB} | jq -r '.data."failure-details".message') | tee -a ${LOGFILE}
            exit 1
        fi
        sleep 5
    done
}

function apply_job() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting APPLY job..." | tee -a ${LOGFILE}
    JOB_ID=$(oci resource-manager job create --stack-id ${STACK_ID} --operation APPLY --apply-job-plan-resolution "{\"isAutoApproved\":true}" --query "data.id" --raw-output)
    echo "Created 'APPLY' job with ID: '${JOB_ID}'" | tee -a ${LOGFILE}
    echo -n "Status for 'APPLY' job:" | tee -a ${LOGFILE}

    while true; do
        OSTATUS=${STATUS}
        JOB=$(oci resource-manager job get --job-id ${JOB_ID})
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
            
            # Send SUCCESS notification to Telegram
            send_telegram "🎉 <b>SUCCESS!</b> 🎉%0A%0A✅ Your Oracle Cloud A1.Flex instance has been created successfully!%0A%0A📅 Date: $(date '+%Y-%m-%d %H:%M:%S')%0A🆔 Job ID: ${JOB_ID}%0A%0ACheck your OCI Console to access your new instance!"
            
            exit 0
        elif [ "${STATUS}" == "FAILED" ]; then
            echo -e "\nThe 'APPLY' job failed. Error message:" | tee -a ${LOGFILE}
            ERROR_MSG=$(echo ${JOB} | jq -r '.data."failure-details".message')
            echo ${ERROR_MSG} | tee -a ${LOGFILE}
            echo -e "\nLogged error:" | tee -a ${LOGFILE}
            echo $(oci resource-manager job get-job-logs-content --job-id ${JOB_ID} --query 'data' --raw-output | grep "Error:") | tee -a ${LOGFILE}
            echo -e "\nRetrying..." | tee -a ${LOGFILE}
            return 1
        fi
        sleep 5
    done
}

WAIT=35
ATTEMPT=0
while true; do
    ATTEMPT=$((ATTEMPT + 1))
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Attempt #${ATTEMPT}" | tee -a ${LOGFILE}
    
    plan_job
    if ! apply_job; then
        sleep ${WAIT}
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Retrying..." | tee -a ${LOGFILE}
        continue
    fi
done
