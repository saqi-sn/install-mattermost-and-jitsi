# Mattermost + Jitsi Deployment Script

A comprehensive bash script for deploying Mattermost (team collaboration) and Jitsi Meet (video conferencing) on Ubuntu servers using Iranian mirrors. Designed for resilient communication during internet outages and network restrictions.

## 🎯 Purpose

This script enables rapid deployment of self-hosted communication infrastructure that remains operational during internet disruptions. By using Iranian mirrors for package downloads, the installation can complete even when international connections are restricted or unavailable.

## ✨ Features

- **Automated Installation**: One-script deployment of both Mattermost and Jitsi Meet
- **Iranian Mirror Support**: Uses local Iranian repositories for faster, more reliable downloads
- **Docker-Based**: Containerized deployment for easy management and portability
- **SSL/TLS Options**: Support for Let's Encrypt or self-signed certificates
- **Security Hardened**: Automatic firewall configuration and secure password generation
- **Resource Validation**: Pre-flight checks for system requirements
- **Comprehensive Logging**: Detailed installation logs for troubleshooting

## 📋 System Requirements

### Minimum Requirements
- **OS**: Ubuntu 20.04, 22.04, or 24.04 LTS
- **RAM**: 4GB (8GB+ recommended with Jitsi)
- **CPU**: 2+ cores
- **Storage**: 20GB+ available disk space
- **Network**: Static IP address or domain name

### Recommended Specifications
- **RAM**: 8GB+ (for smooth video conferencing)
- **CPU**: 4+ cores
- **Storage**: 50GB+ SSD
- **Network**: 100Mbps+ bandwidth

## 🚀 Quick Start

### 1. Prepare Your Server

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Download the script
wget https://your-repo-url/install-mattermost-jitsi.sh
# Or upload the script to your server

# Make it executable
chmod +x install-mattermost-jitsi.sh
```

### 2. Configure DNS (Important!)

Before running the script, ensure your domain(s) point to your server's IP address:

**For Mattermost only:**
- `chat.yourdomain.com` → Your server IP

**For Mattermost + Jitsi:**
- `chat.yourdomain.com` → Your server IP
- `meet.yourdomain.com` → Your server IP

### 3. Run the Installation

```bash
sudo ./install-mattermost-jitsi.sh
```

The script will guide you through an interactive setup process.

## 📝 Installation Options

During installation, you'll be prompted for:

### Required Information
- **Mattermost Domain**: Your Mattermost domain (e.g., `chat.example.com`)
- **Jitsi Installation**: Whether to install Jitsi Meet (yes/no)
- **Jitsi Domain**: Your Jitsi domain if installing (e.g., `meet.example.com`)
- **SSL Certificate**: Whether to use SSL/TLS (recommended)
- **SSL Method**: Let's Encrypt (automatic) or self-signed certificates

### Mattermost Admin Account
- Admin email address
- Admin username
- Admin password (auto-generated or custom)

### Security Options
- All database passwords are automatically generated
- Jitsi authentication credentials are auto-created
- Credentials are saved to `/root/mattermost-jitsi-credentials.txt`

## 🔧 What Gets Installed

### Software Components

1. **Docker & Docker Compose**: Container orchestration
2. **NGINX**: Reverse proxy and web server
3. **PostgreSQL**: Database for Mattermost
4. **Mattermost**: Team collaboration platform
5. **Jitsi Meet** (optional): Video conferencing solution
   - Jitsi Web
   - Jitsi Videobridge (JVB)
   - Jicofo (signaling)
   - Prosody (XMPP server)

### Network Configuration

- **Ports Opened**: 80 (HTTP), 443 (HTTPS), 10000/UDP (Jitsi video)
- **Firewall**: UFW configured automatically
- **DNS**: Set to Iranian DNS servers (217.218.127.127, 217.218.155.155)

### Repositories Configured

- Ubuntu Iranian mirrors (Aut, Yazd, IUST)
- Docker Iranian mirror (dockerhub.ir)
- Docker Compose direct download

## 📂 Installation Paths

```
/opt/mattermost-jitsi/          # Main installation directory
├── mattermost/                 # Mattermost Docker Compose files
│   ├── docker-compose.yml
│   ├── config/
│   ├── data/
│   ├── logs/
│   └── plugins/
└── jitsi/                      # Jitsi Docker Compose files
    ├── docker-compose.yml
    ├── .env
    ├── web/
    ├── transcripts/
    ├── prosody/
    ├── jicofo/
    └── jvb/

/etc/nginx/sites-available/     # NGINX configurations
├── mattermost
└── jitsi

/var/log/mattermost-jitsi-setup.log  # Installation log
/root/mattermost-jitsi-credentials.txt  # Credentials (KEEP SECURE!)
```

## 🔐 Security Best Practices

### Immediately After Installation

1. **Secure Credentials File**
   ```bash
   chmod 600 /root/mattermost-jitsi-credentials.txt
   # Backup to secure location and delete from server
   ```

2. **Update System Regularly**
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

3. **Enable Automatic Security Updates**
   ```bash
   sudo apt install unattended-upgrades
   sudo dpkg-reconfigure -plow unattended-upgrades
   ```

4. **Configure Firewall Rules**
   ```bash
   sudo ufw status verbose
   # Verify only necessary ports are open
   ```

5. **Set Up Fail2Ban** (Recommended)
   ```bash
   sudo apt install fail2ban
   sudo systemctl enable fail2ban
   sudo systemctl start fail2ban
   ```

### SSL/TLS Recommendations

- **Production**: Use Let's Encrypt for valid SSL certificates
- **Testing**: Self-signed certificates are acceptable
- **Renewal**: Let's Encrypt certificates auto-renew (check certbot timer)

## 📱 Accessing Your Services

### Mattermost

```
URL: https://chat.yourdomain.com
```

**First Login:**
1. Navigate to your Mattermost URL
2. Log in with admin credentials from the credentials file
3. Complete the setup wizard
4. Create teams and invite users

### Jitsi Meet

```
URL: https://meet.yourdomain.com
```

**Usage:**
1. Navigate to your Jitsi URL
2. Enter a room name
3. Click "Start meeting"
4. Share the room link with participants

**No authentication required by default** - anyone with the room link can join.

## 🛠️ Management & Maintenance

### Docker Container Management

```bash
# View running containers
docker ps

# View all containers (including stopped)
docker ps -a

# View logs
docker logs -f mattermost-app
docker logs -f jitsi-web
docker logs -f jitsi-prosody

# Restart services
cd /opt/mattermost-jitsi/mattermost
docker-compose restart

cd /opt/mattermost-jitsi/jitsi
docker-compose restart

# Stop services
docker-compose down

# Start services
docker-compose up -d
```

### NGINX Management

```bash
# Test configuration
sudo nginx -t

# Reload configuration
sudo systemctl reload nginx

# Restart NGINX
sudo systemctl restart nginx

# View logs
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/access.log
```

### System Status Checks

```bash
# Check disk usage
df -h

# Check memory usage
free -h

# Check CPU usage
top

# Check Docker disk usage
docker system df

# Clean up unused Docker resources
docker system prune -a
```

## 🔄 Backup & Restore

### Mattermost Backup

```bash
# Create backup directory
mkdir -p /backup/mattermost

# Backup database
docker exec mattermost-postgres pg_dump -U mmuser mattermost > /backup/mattermost/db-$(date +%Y%m%d).sql

# Backup files and configuration
cd /opt/mattermost-jitsi/mattermost
tar -czf /backup/mattermost/mattermost-data-$(date +%Y%m%d).tar.gz config/ data/ plugins/
```

### Jitsi Backup

```bash
# Create backup directory
mkdir -p /backup/jitsi

# Backup configuration
cd /opt/mattermost-jitsi/jitsi
tar -czf /backup/jitsi/jitsi-config-$(date +%Y%m%d).tar.gz .env web/ prosody/ jicofo/ jvb/
```

### Automated Backup Script

```bash
#!/bin/bash
# /root/backup-services.sh

BACKUP_DIR="/backup"
DATE=$(date +%Y%m%d)

# Mattermost
docker exec mattermost-postgres pg_dump -U mmuser mattermost > ${BACKUP_DIR}/mattermost-db-${DATE}.sql
cd /opt/mattermost-jitsi/mattermost
tar -czf ${BACKUP_DIR}/mattermost-data-${DATE}.tar.gz config/ data/ plugins/

# Jitsi
cd /opt/mattermost-jitsi/jitsi
tar -czf ${BACKUP_DIR}/jitsi-config-${DATE}.tar.gz .env web/ prosody/ jicofo/ jvb/

# Delete backups older than 7 days
find ${BACKUP_DIR} -name "*.sql" -mtime +7 -delete
find ${BACKUP_DIR} -name "*.tar.gz" -mtime +7 -delete
```

**Add to crontab:**
```bash
# Daily backup at 2 AM
0 2 * * * /root/backup-services.sh
```

## 🔍 Troubleshooting

### Installation Issues

**DNS Configuration Failed**
```bash
# Manually set DNS
sudo nano /etc/systemd/resolved.conf
# Add: DNS=217.218.127.127 217.218.155.155
sudo systemctl restart systemd-resolved
```

**Docker Installation Failed**
```bash
# Manually install Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io
```

**Let's Encrypt SSL Failed**
```bash
# Check DNS propagation
dig chat.yourdomain.com
nslookup chat.yourdomain.com

# Verify domain points to your server IP
# Try again or use self-signed certificates temporarily
```

### Runtime Issues

**Mattermost Not Accessible**
```bash
# Check if container is running
docker ps | grep mattermost

# Check logs
docker logs mattermost-app

# Check NGINX configuration
sudo nginx -t
sudo systemctl status nginx

# Check firewall
sudo ufw status
```

**Jitsi Video Not Working**
```bash
# Verify UDP port 10000 is open
sudo ufw status | grep 10000

# Check JVB logs
docker logs jitsi-jvb

# Verify domain in .env file
cat /opt/mattermost-jitsi/jitsi/.env | grep PUBLIC_URL
```

**Database Connection Issues**
```bash
# Check PostgreSQL container
docker logs mattermost-postgres

# Verify database credentials
cat /root/mattermost-jitsi-credentials.txt

# Test database connection
docker exec -it mattermost-postgres psql -U mmuser -d mattermost
```

### Performance Issues

**High Memory Usage**
```bash
# Check container resource usage
docker stats

# Restart memory-intensive services
cd /opt/mattermost-jitsi/jitsi
docker-compose restart jvb

# Adjust Docker memory limits in docker-compose.yml
```

**High CPU Usage**
```bash
# Identify resource-heavy containers
docker stats

# Check for video conferencing load
docker logs jitsi-jvb | grep participant

# Consider upgrading server resources
```

## 📚 Additional Configuration

### Integrating Jitsi with Mattermost

1. Log in to Mattermost as admin
2. Go to **System Console** → **Plugins** → **Jitsi**
3. Enable the Jitsi plugin
4. Set Jitsi URL: `https://meet.yourdomain.com`
5. Save settings

### Email Configuration (SMTP)

Edit Mattermost configuration:
```bash
docker exec -it mattermost-app vi /mattermost/config/config.json
```

Or use the System Console → **Environment** → **SMTP** settings.

### User Authentication

**Mattermost:**
- Email/password (default)
- LDAP/AD integration
- SAML 2.0 SSO
- OAuth 2.0 (GitLab, Google, Office 365)

**Jitsi:**
- Enable authentication by editing `.env` file
- Configure Prosody for user authentication
- Set up JWT tokens for secure access

## 🌐 Network Considerations

### For Internet Outages

When international internet is unavailable:
- Mattermost and Jitsi remain fully functional on local network
- Users can access via local domain or IP address
- Video conferencing works without external connectivity
- Iranian mirror support ensures updates can still be downloaded

### Bandwidth Requirements

**Mattermost:**
- Text chat: Minimal bandwidth
- File sharing: Depends on file sizes
- Notifications: Negligible

**Jitsi Video:**
- Audio only: ~100 Kbps per participant
- SD video: ~500 Kbps per participant
- HD video: 1-2 Mbps per participant

## 📞 Support & Documentation

### Official Documentation
- **Mattermost**: https://docs.mattermost.com
- **Jitsi**: https://jitsi.github.io/handbook/

### Useful Resources
- [Mattermost Administrator's Guide](https://docs.mattermost.com/guides/administrator.html)
- [Jitsi Meet Installation Guide](https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-docker)
- [Docker Documentation](https://docs.docker.com/)
- [NGINX Documentation](https://nginx.org/en/docs/)

## ⚠️ Important Notes

1. **Keep credentials secure**: The credentials file contains sensitive passwords
2. **Regular backups**: Set up automated backups for disaster recovery
3. **SSL certificates**: Let's Encrypt certificates expire every 90 days (auto-renewal should be configured)
4. **System updates**: Keep Ubuntu and Docker updated for security patches
5. **Monitoring**: Consider implementing monitoring solutions for production deployments
6. **Scaling**: For large deployments (100+ users), consider dedicated servers for each service

## 📄 License

This script is provided as-is for deployment purposes. Please refer to individual software licenses:
- Mattermost: MIT License (Team Edition)
- Jitsi Meet: Apache License 2.0
- Docker: Apache License 2.0
- NGINX: BSD-like license

## 🤝 Contributing

If you encounter issues or have improvements:
1. Document the issue with logs from `/var/log/mattermost-jitsi-setup.log`
2. Provide system information (`uname -a`, Ubuntu version)
3. Include steps to reproduce the problem

## 🙏 Acknowledgments

- Iranian Ubuntu mirror maintainers for reliable local repositories
- Mattermost and Jitsi communities for excellent open-source software
- Docker for simplifying deployment and management

---

**Created for resilient communication infrastructure during network challenges.**
