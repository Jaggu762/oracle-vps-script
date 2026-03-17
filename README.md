# Oracle Cloud A1.Flex Instance Automation

Automate the provisioning of Oracle Cloud's Always Free A1.Flex ARM instances using OCI Resource Manager and get notified via Telegram when successful.

[![GitHub](https://img.shields.io/badge/GitHub-Jaggu762%2Foracle--vps--script-blue?logo=github)](https://github.com/Jaggu762/oracle-vps-script)

---

> [!TIP]
> **🚀 Quick Stack Creation Tip**  _Rate Limits have been increased to prevent rate limits even with the proper handling_
> You don't need to write Terraform from scratch! When creating an A1.Flex instance through the Oracle Cloud GUI, simply configure all your settings (shape, image, network, SSH keys, etc.) and at the final step, instead of clicking "Create", click **"Save as Stack"**. This automatically generates a Terraform stack with all your configurations, giving you the Stack OCID you need for automation!

---

## ⚡ Quick Start

```bash
# Download the script
curl -o oracle_a1_automation-v2.sh https://raw.githubusercontent.com/Jaggu762/oracle-vps-script/main/oracle_a1_automation-v2.sh

# Make it executable
chmod +x oracle_a1_automation-v2.sh

# Edit configuration (add your Stack OCID, Telegram bot token, and chat ID)
nano oracle_a1_automation-v2.sh

# Run in screen session
screen -S oracle-automation
./oracle_a1_automation-v2.sh

# Detach: Ctrl+A, then D
```

---

## 🎯 Problem Statement

Oracle Cloud's Always Free tier offers powerful A1.Flex ARM instances (up to 4 OCPUs, 24GB RAM), but they're almost never available due to high demand. Instead of manually refreshing the console hoping for capacity, this script automates the entire process.

## ✨ Features

- **24/7 Automated Retries** - Runs continuously until successful
- **Stack-based Deployment** - More reliable than manual instance creation
- **Auto Stack Discovery (Optional)** - If `STACK_ID` is not set, script tries to find one automatically
- **Telegram Notifications** - Get instant alerts when your instance is created
- **Detailed Logging** - Track all attempts and errors
- **429 Rate-Limit Protection** - Exponential backoff + jitter for Resource Manager API throttling
- **Anti-Crash Retry Flow** - Transient PLAN/APPLY API failures no longer stop the script
- **Graceful Stop Handling** - `Ctrl+C` exits cleanly without false crash alerts
- **Uses Existing E2 Micro** - Leverages your always-available free instance

### Retry Tuning

`oracle_a1_automation-v2.sh` includes these variables at the top:

- `BASE_WAIT` - Base retry wait between attempts (default `35` seconds)
- `MAX_WAIT` - Maximum capped retry wait (default `600` seconds)
- `OCI_MAX_RETRIES` - Retries for a single OCI API call (default `8`)
- `OCI_BASE_DELAY` - Base delay for OCI API retry backoff (default `8` seconds)
- `OCI_MAX_DELAY` - Maximum OCI API retry delay (default `180` seconds)
- `JOB_POLL_WAIT` - Poll interval for PLAN/APPLY job status checks (default `15` seconds)
- `TELEGRAM_RATE_LIMIT_COOLDOWN` - Cooldown for repeated rate-limit alerts (default `900` seconds)

Suggested first-time setup:

- Set `STACK_ID` manually for the most predictable behavior.
- Keep `COMPARTMENT_ID` only as a fallback helper.
- Keep retry defaults unless you are hitting unusual API limits.

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

> [!NOTE]
> **Easiest Method**: Use the Oracle Cloud GUI to create your stack instead of writing Terraform manually!

### Method 1: Create Stack from GUI (Recommended ⭐)

1. Go to **OCI Console → Compute → Instances**
2. Click **Create Instance**
3. Configure your A1.Flex instance:
   - **Name**: `a1-free-instance`
   - **Image**: Select Ubuntu or Oracle Linux (ARM-based)
   - **Shape**: Click "Change Shape" → Select `VM.Standard.A1.Flex`
   - **OCPUs**: 4 (max for free tier)
   - **Memory**: 24 GB (max for free tier)
   - **Network**: Select your VCN and subnet
   - **SSH Keys**: Add your public SSH key
4. **Instead of clicking "Create"**, scroll down and click **"Save as Stack"**
5. Give your stack a name (e.g., `a1-automation-stack`)
6. Click **Save**
7. **Copy the Stack OCID** from the stack details page

That's it! You now have a Terraform stack without writing any code.

### Method 2: Manual Terraform Configuration

If you prefer to write Terraform manually:

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

### Step 3: Create Stack in OCI Console (Manual Method Only)

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
curl -o oracle_a1_automation-v2.sh https://raw.githubusercontent.com/Jaggu762/oracle-vps-script/main/oracle_a1_automation-v2.sh
```

### Step 2: Configure the Script

Edit the file and replace:
- `your-stack-ocid-here` with your Stack OCID (recommended)
- `your-bot-token-here` with your Telegram Bot Token
- `your-chat-id-here` with your Telegram Chat ID

Notes:

- If `STACK_ID` is left as placeholder, the script will try to auto-discover a stack from your tenant.
- Auto-discovery is convenient, but manual `STACK_ID` is safer in accounts with multiple stacks.

```bash
nano oracle_a1_automation-v2.sh
```

### Step 3: Make Script Executable

```bash
chmod +x oracle_a1_automation-v2.sh
```

---

## ▶️ Running the Automation

### Start the Script in Screen

```bash
# Create a new screen session
screen -S oracle-automation

# Run the script
./oracle_a1_automation-v2.sh
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
2. **Continuous attempts** → It runs PLAN + APPLY in a loop until capacity is available
3. **Smart backoff** → On 429/transient API errors, it backs off automatically (with jitter)
4. **Success!** → You get a Telegram notification with instance details
5. **Script exits** → Automation stops (you got your instance!)

### Expected Timeline
- Could be **hours** to **days** depending on Oracle's capacity
- Most users report success within **24-48 hours**
- Some get lucky within the first hour!
- During heavy throttling windows, retries may slow down by design to avoid tenant-level 429 blocks

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

### Frequent 429 (TooManyRequests)

- This is normal during crowded hours in popular regions.
- Let the script run; it now uses exponential backoff and jitter automatically.
- If needed, increase `BASE_WAIT` (for gentler loops) or `OCI_BASE_DELAY` (for slower API retries).

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
