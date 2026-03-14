# Oracle Cloud A1.Flex Instance Automation

Automate the provisioning of Oracle Cloud's Always Free A1.Flex ARM instances using OCI Resource Manager and get notified via Telegram when successful.

## 🎯 Problem Statement

Oracle Cloud's Always Free tier offers powerful A1.Flex ARM instances (up to 4 OCPUs, 24GB RAM), but they're almost never available due to high demand. Instead of manually refreshing the console hoping for capacity, this script automates the entire process.

## ✨ Features

- **24/7 Automated Retries** - Runs continuously until successful
- **Stack-based Deployment** - More reliable than manual instance creation
- **Telegram Notifications** - Get instant alerts when your instance is created
- **Detailed Logging** - Track all attempts and errors
- **Uses Existing E2 Micro** - Leverages your always-available free instance

## 📋 Prerequisites

### Required
- An Oracle Cloud account with Always Free tier
- An existing **E2 Micro instance** (this will run the automation)
- Basic Linux/SSH knowledge

### What You'll Get
- **A1.Flex Instance**: ARM Ampere processor, up to 4 OCPUs and 24GB RAM
- **Always Free**: No charges, runs indefinitely

---

## 🚀 Installation

### Step 1: Connect to Your E2 Micro Instance

```bash
ssh -i /path/to/your/private-key ubuntu@your-instance-ip
```

### Step 2: Update System and Install Dependencies

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install required tools
sudo apt install -y jq curl screen
```

### Step 3: Install OCI CLI

```bash
# Download and install OCI CLI
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# Reload shell
exec bash -l
```

During installation:
- Press `Enter` for default install location
- Type `Y` to update PATH
- Type `Y` to install optional packages

### Step 4: Configure OCI CLI

```bash
oci setup config
```

You'll need:
- **User OCID**: OCI Console → Profile → User Settings
- **Tenancy OCID**: OCI Console → Profile → Tenancy
- **Region**: Your home region (e.g., `ap-mumbai-1`)
- **Generate API Key**: Type `Y`

### Step 5: Upload API Key to OCI Console

```bash
# Display your public key
cat ~/.oci/oci_api_key_public.pem
```

Then:
1. Go to **OCI Console → Profile → User Settings → API Keys**
2. Click **Add API Key**
3. Select **Paste Public Key**
4. Paste the entire key
5. Click **Add**

### Step 6: Verify OCI CLI Works

```bash
oci iam region list
```

You should see a JSON list of Oracle Cloud regions.

---

## 🤖 Telegram Bot Setup

### Step 1: Create a Telegram Bot

1. Open Telegram and search for `@BotFather`
2. Send `/newbot`
3. Follow prompts to name your bot
4. **Copy the Bot Token** (looks like `123456789:ABCdefGHI...`)

### Step 2: Get Your Chat ID

**Method 1: Using a Bot**
1. Search for `@RawDataBot` or `@getmyid_bot` on Telegram
2. Send `/start`
3. Copy your Chat ID

**Method 2: Using API**
1. Send any message to your bot
2. Run this command:
```bash
curl https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates
```
3. Look for `"chat":{"id":123456789}` - that's your Chat ID

### Step 3: Test Telegram Notifications

```bash
curl -X POST "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/sendMessage" \
  -d chat_id="<YOUR_CHAT_ID>" \
  -d text="Test! Automation is working!"
```

You should receive a message on Telegram.

---

## 📝 Create Terraform Stack

### Step 1: Find Required Information

You'll need:
- **Compartment OCID**: OCI Console → Identity → Compartments
- **Subnet OCID**: OCI Console → Networking → Virtual Cloud Networks → Your VCN → Subnets
- **Image OCID**: OCI Console → Compute → Custom Images (or use public images)
- **Availability Domain**: Your region's AD (e.g., `BqXC:AP-MUMBAI-1-AD-1`)

### Step 2: Create Terraform Configuration

Create a file `main.tf`:

```hcl
variable "compartment_id" {
  default = "ocid1.compartment.oc1..aaa..."
}

variable "availability_domain" {
  default = "BqXC:AP-MUMBAI-1-AD-1"
}

variable "subnet_id" {
  default = "ocid1.subnet.oc1..aaa..."
}

resource "oci_core_instance" "a1_instance" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  shape              = "VM.Standard.A1.Flex"
  display_name       = "a1-free-instance"

  shape_config {
    ocpus         = 4
    memory_in_gbs = 24
  }

  source_details {
    source_type = "image"
    source_id   = "ocid1.image.oc1..aaa..."  # Ubuntu ARM image
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = file("~/.ssh/id_rsa.pub")
  }
}

output "instance_public_ip" {
  value = oci_core_instance.a1_instance.public_ip
}
```

### Step 3: Create Stack in OCI Console

1. Go to **Developer Services → Resource Manager → Stacks**
2. Click **Create Stack**
3. Choose **My Configuration**
4. Upload your `main.tf` file
5. Click **Next**, configure variables
6. Click **Create**
7. **Copy the Stack OCID** (you'll need this!)

---

## 🔧 Automation Script Setup

### Step 1: Download the Script

```bash
nano oracle_a1_automation.sh
```

Paste this content:

```bash
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
```

### Step 2: Configure the Script

Edit the file and replace:
- `your-stack-ocid-here` with your Stack OCID
- `your-bot-token-here` with your Telegram Bot Token
- `your-chat-id-here` with your Telegram Chat ID

```bash
nano oracle_a1_automation.sh
```

### Step 3: Make Script Executable

```bash
chmod +x oracle_a1_automation.sh
```

---

## ▶️ Running the Automation

### Start the Script in Screen

```bash
# Create a new screen session
screen -S oracle-automation

# Run the script
./oracle_a1_automation.sh
```

### Detach from Screen (Leave Running)

Press: `Ctrl + A`, then `D`

The script will continue running in the background.

---

## 📊 Monitoring

### View the Log File

```bash
tail -f oracle_automation_v2.log
```

### Reattach to Screen Session

```bash
screen -r oracle-automation
```

### List All Screen Sessions

```bash
screen -ls
```

### Stop the Script

```bash
# Reattach to screen
screen -r oracle-automation

# Stop script
Ctrl + C

# Exit screen
exit
```

---

## 🎯 What Happens Next

1. **Script starts** → You receive a Telegram notification
2. **Continuous attempts** → Every 35 seconds, it tries to create the instance
3. **Success!** → You get a Telegram notification with instance details
4. **Script exits** → Automation stops (you got your instance!)

### Expected Timeline
- Could be **hours** to **days** depending on Oracle's capacity
- Most users report success within **24-48 hours**
- Some get lucky within the first hour!

---

## 🛠️ Troubleshooting

### OCI CLI Authentication Errors

```bash
# Check your config
cat ~/.oci/config

# Verify API key is uploaded to OCI Console
oci iam region list
```

### Telegram Not Working

```bash
# Test manually
curl -X POST "https://api.telegram.org/bot<BOT_TOKEN>/sendMessage" \
  -d chat_id="<CHAT_ID>" \
  -d text="Test"
```

### Script Stops Unexpectedly

- Make sure you're running it inside `screen` or `tmux`
- Check the log file: `cat oracle_automation_v2.log`

### Stack Creation Errors

- Verify all OCIDs are correct
- Check you have available quota
- Ensure subnet and VCN are configured properly

---

## 📚 Useful Commands

### Screen Commands

| Action | Command |
|--------|---------|
| Create session | `screen -S oracle-automation` |
| Detach | `Ctrl+A, D` |
| Reattach | `screen -r oracle-automation` |
| List sessions | `screen -ls` |
| Kill session | `screen -X -S oracle-automation quit` |

### Tmux Commands (Alternative)

| Action | Command |
|--------|---------|
| Create session | `tmux new -s oracle-automation` |
| Detach | `Ctrl+B, D` |
| Reattach | `tmux attach -t oracle-automation` |
| List sessions | `tmux ls` |
| Kill session | `tmux kill-session -t oracle-automation` |

---

## 🤝 Contributing

Found an improvement? Have a suggestion? Feel free to:
- Open an issue
- Submit a pull request
- Share your success story!

---

## ⚠️ Disclaimer

- This script is for educational purposes
- Use at your own risk
- Oracle may change their policies at any time
- Always comply with Oracle Cloud's Terms of Service

---

## 📖 Resources

- [Oracle Cloud Free Tier](https://www.oracle.com/cloud/free/)
- [OCI CLI Documentation](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm)
- [Terraform OCI Provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)
- [Oracle Resource Manager](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/home.htm)

---

## 📄 License

MIT License - Feel free to use and modify!

---

## 🎉 Success!

Once you receive the success notification on Telegram:

1. Go to **OCI Console → Compute → Instances**
2. Find your new A1.Flex instance
3. Note the public IP address
4. SSH into your new ARM instance:
   ```bash
   ssh ubuntu@<instance-public-ip>
   ```

Enjoy your powerful free ARM server! 🚀

---

## 👨‍💻 Author

**Jaggu762**

---

**Made with ❤️ for the Oracle Cloud community**
