# 🚀 Advanced DBT on Snowflake: CI/CD and Dynamic Task Orchestration

**Enterprise-grade automation for modern data pipelines using DBT Projects on Snowflake**

[![DBT Version](https://img.shields.io/badge/dbt-1.9.2-orange.svg)](https://docs.getdbt.com/)
[![Snowflake](https://img.shields.io/badge/Snowflake-Enterprise-blue.svg)](https://www.snowflake.com/)
[![GitOps](https://img.shields.io/badge/GitOps-Enabled-green.svg)](https://about.gitlab.com/topics/gitops/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 📖 About This Project

This repository demonstrates how to transform manual DBT operations into enterprise-grade, automated data pipelines using Snowflake's native DBT Projects feature. Built around the **Tasty Bytes** food truck analytics platform, it showcases medallion architecture implementation with advanced CI/CD automation.

### 🎯 What You'll Learn

- **Dynamic Task Orchestration**: JSON-driven pipeline configuration
- **Intelligent Change Detection**: SHA-256 hashing for efficient deployments  
- **GitOps Workflows**: Complete CI/CD automation for data teams
- **Production-Ready Patterns**: From startup agility to enterprise scale
- **Medallion Architecture**: Bronze, Silver, Gold data layer implementation

## 🏗️ Architecture Overview

```mermaid
graph TB
    A[Git Repository] --> B[GitHub Actions CI/CD]
    B --> C[Snowflake CLI Deployment]
    C --> D[DBT Project Deployment]
    C --> E[Stored Procedures]
    C --> F[JSON Configuration Processing]
    F --> G[Dynamic Task Creation]
    G --> H[Medallion Architecture Pipeline]
    
    H --> I[Bronze Layer - Raw Data]
    H --> J[Silver Layer - Cleaned Data]
    H --> K[Gold Layer - Business Ready]
```

## 📚 Article Series

This repository is part of a comprehensive **Modern Data Stack** article series:

1. **[Part 1: Theoretical Foundation](https://medium.com/@vikneshwararb_99226/modern-data-stack-for-analytics-medallion-architecture-dbt-the-elt-revolution-and-snowflake-45ee91ca6c14)**  
   *Medallion Architecture, ELT Revolution, and DBT Fundamentals*

2. **[Part 2: Hands-On Implementation](https://medium.com/@vikneshwararb_99226/modern-data-stack-in-action-practical-guide-to-build-data-pipelines-with-dbt-projects-feature-on-592e5eb135c9)**  
   *Manual DBT implementation with Tasty Bytes use case*

3. **[Part 3: Enterprise Automation](https://medium.com/@vikneshwararb_99226/implementing-ci-cd-and-dynamic-task-orchestration-using-dbt-snowflake-projects-6397fb572a51)** ⬅️ **This Repository**  
   *CI/CD automation and dynamic orchestration*

## 🚀 Quick Start

### Prerequisites

- **Snowflake Enterprise Edition** with ACCOUNTADMIN privileges
- **GitHub Account** with repository management access
- **Git** installed locally
- **Basic understanding** of DBT and Snowflake concepts

### 1. Fork and Clone

```bash
git clone https://github.com/<your-username>/food_truck_analytics.git
cd food_truck_analytics
git checkout release/v.1.1
```

### 2. Generate RSA Keypair for Authentication

This project uses **RSA keypair authentication** with **passphrase protection** for enhanced security. The passphrase adds an additional layer of encryption to your private key.

#### 2.1. Generate Passphrase-Protected RSA Keypair

Execute the following commands in your terminal:

```bash
# Generate 4096-bit RSA private key with AES-256 encryption (recommended for production)
openssl genrsa -aes256 -out snowflake_rsa_key.pem 4096
# You will be prompted to enter and confirm a passphrase - choose a strong passphrase

# Generate public key from private key
openssl rsa -in snowflake_rsa_key.pem -pubout -out snowflake_rsa_key.pub
# You will be prompted to enter your passphrase to decrypt the private key

# Extract public key content (remove headers for Snowflake)
grep -v "BEGIN\|END\|PUBLIC KEY" snowflake_rsa_key.pub | tr -d '\n' > snowflake_public_key.txt

# Display the public key content for copying
cat snowflake_public_key.txt
```

**Alternative: Generate Unencrypted Key (Less Secure)**

If you prefer not to use a passphrase (not recommended for production):

```bash
# Generate 4096-bit RSA private key without passphrase
openssl genrsa -out snowflake_rsa_key.pem 4096

# Generate public key from private key
openssl rsa -in snowflake_rsa_key.pem -pubout -out snowflake_rsa_key.pub

# Extract public key content (remove headers for Snowflake)
grep -v "BEGIN\|END\|PUBLIC KEY" snowflake_rsa_key.pub | tr -d '\n' > snowflake_public_key.txt

# Display the public key content for copying
cat snowflake_public_key.txt
```

#### 2.2. Configure Snowflake User for Keypair Authentication

Connect to Snowflake as **ACCOUNTADMIN** and execute the following SQL commands:

```sql
-- Switch to ACCOUNTADMIN role
USE ROLE ACCOUNTADMIN;

-- Set RSA public key for the DBT user (enables keypair authentication)
-- Replace 'your_public_key_content_here' with the content from snowflake_public_key.txt
ALTER USER DBT_USER SET RSA_PUBLIC_KEY = 'your_public_key_content_here';

-- Verify the configuration (optional)
DESCRIBE USER DBT_USER;

-- Note: The user now supports BOTH password and keypair authentication methods
-- Password authentication remains available for manual connections if needed
```

**Important Security Notes:**
- Keep your **private key file** (`snowflake_rsa_key.pem`) and **passphrase** secure and never commit them to version control
- Add `*.pem` and `*.key` to your `.gitignore` file
- The **public key** can be safely shared and stored in Snowflake
- This configuration allows **dual authentication** - both password and keypair methods work
- For production, always use **passphrase-protected** keys for enhanced security
- Consider using **keypair-only** authentication by removing password access
- Rotate your keys and passphrases every 90 days for optimal security

### 3. Configure GitHub Secrets

Navigate to **Settings → Secrets and variables → Actions** in your forked repository:

#### 3.1. Repository Secrets

**For Passphrase-Protected Keys (Recommended):**
```
SNOWFLAKE_ACCOUNT=your-account-identifier
SNOWFLAKE_USER=DBT_USER
SNOWFLAKE_PRIVATE_KEY=your-encrypted-rsa-private-key-content
SNOWFLAKE_PRIVATE_KEY_PASSPHRASE=your-passphrase
```

**For Unencrypted Keys (Less Secure):**
```
SNOWFLAKE_ACCOUNT=your-account-identifier
SNOWFLAKE_USER=DBT_USER
SNOWFLAKE_PRIVATE_KEY=your-rsa-private-key-content
```

**To get the private key content:**
```bash
# Copy the entire private key content including headers
cat snowflake_rsa_key.pem
```

Copy the **entire output** (including `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----` lines for unencrypted keys, or `-----BEGIN ENCRYPTED PRIVATE KEY-----` and `-----END ENCRYPTED PRIVATE KEY-----` for encrypted keys) and paste it as the `SNOWFLAKE_PRIVATE_KEY` secret value.

**Important Notes:**
- If you generated a passphrase-protected key, you **must** add the `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` secret
- The passphrase is the one you entered when generating the key with `openssl genrsa -aes256`
- The CI/CD pipeline will automatically decrypt the key using the passphrase during deployment
- Keep both the private key and passphrase secure and never commit them to version control

#### 3.2. Repository Variables
```
SNOWFLAKE_DATABASE=TASTY_BYTES_ANALYTICS_DB
SNOWFLAKE_SCHEMA=INTEGRATIONS
SNOWFLAKE_WAREHOUSE=TASTY_BYTES_DBT_WH
SNOWFLAKE_ROLE=DBT_DEV_ROLE
```

### 4. Initial Snowflake Setup

Execute the setup script in Snowflake to create required infrastructure:

```sql
-- Run as ACCOUNTADMIN
@initial_setup_and_ingestion/snowflake_setup.sql
```

### 5. Deploy Stored Procedures

```sql
-- Deploy the dynamic task framework
@orchestration_setup/config_driven_sp_definitions.sql
```

### 6. Trigger Deployment

Make any change to `metadata/tasty_bytes.json` and push to trigger the automated CI/CD pipeline.

## 📁 Repository Structure

```
food_truck_analytics/
├── .github/workflows/
│   └── dbt-snowflake-cicd-deploy.yml    # CI/CD pipeline definition
├── metadata/
│   └── tasty_bytes.json                 # Task configuration file
├── orchestration_setup/
│   └── config_driven_sp_definitions.sql # Stored procedure framework
├── models/
│   ├── staging/                         # Silver layer models
│   ├── intermediate/                    # Silver enrichment  
│   ├── core/                           # Gold dimensional models
│   └── analytics/                      # Gold business aggregates
├── initial_setup_and_ingestion/
│   └── tasty_bytes_enhanced_data_load.sql
├── dbt_project.yml                     # DBT project configuration
├── packages.yml                        # DBT dependencies
└── README.md                           # This file
```

## 🔧 Key Features

### ⚡ Dynamic Task Orchestration

JSON-driven configuration enables declarative pipeline management:

```json
{
  "project_config": {
    "database": "TASTY_BYTES_ANALYTICS_DB",
    "schema": "INTEGRATIONS",
    "project_name": "FOOD_TRUCK_ANALYTICS_DBT_PROJECT"
  },
  "tasks": [
    {
      "name": "silver_staging_setup",
      "enabled": true,
      "dbt_command": "run --select tag:silver,tag:staging",
      "depends_on": [],
      "schedule": "USING CRON 0 9-17 * * * UTC"
    }
  ]
}
```

### 🔍 Intelligent Change Detection

SHA-256 hashing ensures efficient deployments:
- **Zero-downtime**: Skip deployments when no changes exist
- **Audit trail**: Complete history of configuration changes  
- **Rollback capability**: Reference previous configurations for recovery

### 🛡️ Advanced Validation

- **Circular dependency detection** prevents infinite loops
- **Configuration schema validation** ensures structural integrity
- **Enabled task filtering** handles complex dependency chains

### 📊 Comprehensive Monitoring

Built-in observability and audit capabilities:

```sql
-- Monitor recent deployments
CALL show_task_creation_log('tasty_bytes');

-- View current feed status  
CALL show_feed_task_status('tasty_bytes');

-- List all feeds
CALL list_all_feeds();
```

## 🎮 Usage Examples

### Deploy a New Feed

1. Create JSON configuration in `metadata/` directory
2. Commit and push changes
3. CI/CD automatically validates and deploys
4. Monitor execution through Snowflake Task History

### Modify Existing Pipeline

1. Update task dependencies in JSON configuration
2. Push changes to trigger change detection
3. Only modified tasks are updated (zero downtime)
4. Verify deployment through monitoring procedures

### Emergency Rollback

```sql
-- Find previous working configuration
SELECT config_hash, loaded_at 
FROM dbt_task_config 
WHERE feed_name = 'my_feed' AND execution_status = 'SUCCESS'
ORDER BY loaded_at DESC;

-- Rollback to previous version
UPDATE dbt_task_config 
SET is_current = TRUE 
WHERE feed_name = 'my_feed' AND config_hash = 'previous_hash';
```

### Development Setup

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Make your changes and test thoroughly
4. Commit your changes: `git commit -m 'Add amazing feature'`
5. Push to the branch: `git push origin feature/amazing-feature`
6. Open a Pull Request


## 🛠️ Troubleshooting

### Common Issues

**Pipeline Fails During Deployment:**
```bash
# Check CI/CD logs in GitHub Actions
# Verify Snowflake credentials in repository secrets
# Validate JSON configuration syntax
```

**Failed to Decrypt Private Key:**
- **Cause**: Wrong passphrase or incorrect key format
- **Solution**: Verify your key is encrypted and test passphrase locally
```bash
# Verify your key is encrypted
head -n 1 snowflake_rsa_key.pem
# Should show: -----BEGIN ENCRYPTED PRIVATE KEY-----

# Test decryption locally
openssl rsa -in snowflake_rsa_key.pem -check
# Enter your passphrase - if this fails, the passphrase is wrong
```

**Private Key Validation Failed:**
- **Cause**: Key file corrupted or incomplete
- **Solution**: Check key integrity
```bash
openssl rsa -in snowflake_rsa_key.pem -text -noout
# This should display key details without errors
```

**No Passphrase Configured Warning:**
- **Cause**: `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` secret not set
- **Solution**: Add the secret in GitHub repository settings

**Tasks Not Created:**
```sql
-- Verify stored procedures are deployed
SHOW PROCEDURES LIKE '%dbt%';

-- Check configuration loading
SELECT * FROM dbt_task_config WHERE feed_name = 'your_feed';
```

**Change Detection Not Working:**
```sql
-- Manually check for changes
CALL has_config_changes('feed_name', 'config.json');
```

## 🔐 Security Best Practices

### Key Management

**Passphrase Requirements:**
- Minimum 20 characters long
- Include uppercase, lowercase, numbers, and special characters
- Use unique passphrases (don't reuse)
- Store in password manager (1Password, LastPass, Bitwarden)

**Generate Strong Passphrase:**
```bash
# Generate a random 32-character passphrase
openssl rand -base64 32
```

**Never:**
- ❌ Commit private keys or passphrases to version control
- ❌ Share passphrases via email or chat
- ❌ Use the same passphrase for multiple keys
- ❌ Store passphrases in plain text files

**Always:**
- ✅ Use passphrase-protected keys in production
- ✅ Store secrets in GitHub Secrets
- ✅ Add `*.pem` and `*.key` to `.gitignore`
- ✅ Rotate keys every 90 days

### Key Rotation Procedure

**Rotate keys every 90 days for production environments:**

```bash
# 1. Generate new passphrase-protected keypair
openssl genrsa -aes256 -out snowflake_rsa_key_new.pem 4096
openssl rsa -in snowflake_rsa_key_new.pem -pubout -out snowflake_rsa_key_new.pub
grep -v "BEGIN\|END\|PUBLIC KEY" snowflake_rsa_key_new.pub | tr -d '\n' > snowflake_public_key_new.txt
```

```sql
-- 2. Add new key to Snowflake (supports 2 keys simultaneously)
USE ROLE ACCOUNTADMIN;
ALTER USER DBT_USER SET RSA_PUBLIC_KEY_2 = 'new_public_key_content_here';

-- 3. Update GitHub secrets with new key and passphrase
-- 4. Test deployment with new key

-- 5. Remove old key after verification
ALTER USER DBT_USER SET RSA_PUBLIC_KEY = 'new_public_key_content_here';
ALTER USER DBT_USER UNSET RSA_PUBLIC_KEY_2;
```

```bash
# 6. Securely delete old key files
shred -vfz -n 10 snowflake_rsa_key.pem
```

### Monitoring and Auditing

**Monitor Authentication:**
```sql
-- Check for failed login attempts
SELECT 
    event_timestamp,
    user_name,
    client_ip,
    reported_client_type,
    execution_status
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE user_name = 'DBT_USER'
    AND is_success = 'NO'
    AND event_timestamp >= DATEADD(day, -7, CURRENT_TIMESTAMP())
ORDER BY event_timestamp DESC;

-- Monitor task executions
SELECT 
    name,
    state,
    scheduled_time,
    completed_time,
    error_code,
    error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 100
))
WHERE name LIKE '%DBT%'
ORDER BY scheduled_time DESC;
```

### GitHub Actions Workflow Security

**The workflow includes:**
- ✅ Automatic key decryption using OpenSSL
- ✅ Private key validation before use
- ✅ Secure cleanup of temporary files
- ✅ Secrets redacted in logs
- ✅ Support for both encrypted and unencrypted keys

**Workflow Status Indicators:**
- ✅ "Private key decrypted successfully" - Passphrase authentication working
- ✅ "Private key is valid" - Key integrity verified
- ⚠️ "No passphrase configured" - Using unencrypted key (not recommended for production)
- ❌ "Failed to decrypt private key" - Check passphrase

### Incident Response

**If you suspect a key compromise:**

1. **Immediate Actions (within 1 hour):**
   ```sql
   -- Disable the user immediately
   USE ROLE ACCOUNTADMIN;
   ALTER USER DBT_USER SET DISABLED = TRUE;
   ```

2. **Delete compromised secrets from GitHub:**
   - Settings → Secrets → Delete `SNOWFLAKE_PRIVATE_KEY` and `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE`

3. **Generate new keypair and passphrase**

4. **Audit what was accessed:**
   ```sql
   SELECT query_text, start_time, user_name, role_name
   FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
   WHERE user_name = 'DBT_USER'
       AND start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
   ORDER BY start_time DESC;
   ```

## 📋 Requirements

- **Snowflake**: Enterprise Edition (for DBT Projects feature)
- **DBT**: Version 1.9.2 or higher
- **GitHub Actions**: Enabled for CI/CD automation
- **Git**: Version 2.0 or higher

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Snowflake** for the innovative DBT Projects feature
- **DBT Labs** for the foundational data transformation framework
- **Tasty Bytes** sample data for realistic use case scenarios

## 📞 Support & Community

- **Issues**: [GitHub Issues](https://github.com/vikneshwara-r-b/food_truck_analytics/issues)
- **Discussions**: [GitHub Discussions](https://github.com/vikneshwara-r-b/food_truck_analytics/discussions)
- **LinkedIn**: [Connect with the author](https://www.linkedin.com/in/vikneshwararb/)

---

## 🌟 Star This Repository

If this project helped you implement modern data stack automation, please ⭐ star this repository to show your support!

---

*Built with ❤️ for the data engineering community*
