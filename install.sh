#!/bin/bash

# --- Utility Functions ---

log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') INFO: $1" >> /var/log/bastion-install.log
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: $1" >> /var/log/bastion-install.log
    exit 1
}

# --- Global Parameters ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_info "Working directory: $SCRIPT_DIR"

# Guacamole

GUACD_TAR="guacamole-server-1.5.5.tar.gz"
GUAC_WAR="guacamole-1.5.5.war"
GUAC_JDBC_TAR="guacamole-auth-jdbc-1.5.5.tar.gz"

# TOMCAT 9 (Manual Installation since it's not in Ubuntu 24.04 repos)

TOMCAT_TAR="apache-tomcat-9.0.105.tar.gz"
TOMCAT_INSTALL_DIR="/opt/tomcat"
TOMCAT_USER="tomcat"
TOMCAT_GROUP="tomcat"
TOMCAT_ADMIN_USER="bastion" # Default Tomcat Manager/Admin user
TOMCAT_ADMIN_PASSWORD="D9D24011-58BD-462F-87FA-1AC4940A2C53"

# POSTGRESQL DATABASE

POSTGRESQL_JDBC_JAR="postgresql-42.7.3.jar"
POSTGRES_ROOT_PASSWORD="A330B513-9D41-44A5-9FFE-F5D4D87C1AC9"
POSTGRESQL_GUAC_DB_NAME="guacamole_db"
POSTGRESQL_GUAC_DB_USER="guacamole_user"


command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- Installation Functions ---

install_system_dependencies() {
    log_info "Updating system package list and upgrading packages..."
    sudo apt update -y || log_error "Failed to update apt."
    sudo apt upgrade -y || log_error "Failed to upgrade packages. Manual intervention might be needed."

    log_info "Installing core build tools, Java (OpenJDK), and PostgreSQL..."
    sudo apt install -y build-essential libcairo2-dev libjpeg-turbo8-dev \
    libpng-dev libtool-bin libossp-uuid-dev libvncserver-dev freerdp2-dev \
    libssh2-1-dev libtelnet-dev libwebsockets-dev libpulse-dev libvorbis-dev \
    libwebp-dev libssl-dev libpango1.0-dev libswscale-dev libavcodec-dev \
    libavutil-dev libavformat-dev gcc make wget curl default-jdk \
    postgresql postgresql-contrib libpq-dev || log_error "Failed to install system dependencies."
    log_info "System dependencies installed."
}

setup_guacd() {
    log_info "Building guacd (Guacamole Server)..."
    local GUACD_DIR="/tmp/guacamole-server"
    sudo mkdir -p "$GUACD_DIR"

    sudo tar -xzf "$SCRIPT_DIR/$GUACD_TAR" --strip-components=1 -C "$GUACD_DIR" || log_error "Failed to extract guacd source."

    cd "$GUACD_DIR" || log_error "Failed to change directory to $GUACD_DIR."

    # Configure with PostgreSQL (libpq) support
    sudo ./configure --with-init-dir=/etc/init.d --disable-guacenc --with-libpq || log_error "Failed to configure guacd."
    sudo make || log_error "Failed to compile guacd."
    sudo make install || log_error "Failed to install guacd."
    sudo ldconfig # Update the system's cache of installed libraries

    log_info "Enabling and starting guacd service..."
    sudo systemctl daemon-reload || log_error "Failed to reload systemd daemon."
    sudo systemctl enable guacd || log_error "Failed to enable guacd service."
    sudo systemctl start guacd || log_error "Failed to start guacd service. Check logs (journalctl -xeu guacd)."
    log_info "guacd built and started."
}

setup_tomcat9_manual() {
    log_info "Setting up Apache Tomcat manually..."

    # Determine JAVA_HOME path
    local JAVA_HOME_PATH=$(readlink -f /usr/bin/java | sed "s:bin/java::")
    if [ -z "$JAVA_HOME_PATH" ]; then
        log_error "Could not determine JAVA_HOME. Please set it manually or verify Java installation."
    fi
    log_info "Detected JAVA_HOME: $JAVA_HOME_PATH"

    # Create Tomcat User and Group
    log_info "Creating Tomcat user and group '$TOMCAT_USER'..."
    sudo groupadd "$TOMCAT_GROUP" 2>/dev/null || log_info "Group '$TOMCAT_GROUP' already exists."
    sudo useradd -r -M -d "$TOMCAT_INSTALL_DIR" -s /bin/false "$TOMCAT_USER" -g "$TOMCAT_GROUP" 2>/dev/null || log_info "User '$TOMCAT_USER' already exists."

    # Extract Tomcat
    log_info "Extracting Apache Tomcat..."
    sudo mkdir -p "$TOMCAT_INSTALL_DIR" || log_error "Failed to create Tomcat installation directory."
    sudo tar -xzf "$SCRIPT_DIR/${TOMCAT_TAR}" -C "$TOMCAT_INSTALL_DIR" --strip-components=1 || log_error "Failed to extract Tomcat."

    # Set Permissions
    log_info "Setting permissions for Tomcat installation..."
    sudo chown -R "$TOMCAT_USER":"$TOMCAT_GROUP" "$TOMCAT_INSTALL_DIR" || log_error "Failed to set Tomcat directory ownership."
    sudo chmod -R g+r "$TOMCAT_INSTALL_DIR"/conf || log_error "Failed to set read permissions on Tomcat conf."
    sudo chmod g+x "$TOMCAT_INSTALL_DIR"/conf || log_error "Failed to set execute permissions on Tomcat conf."
    sudo chown -R "$TOMCAT_USER":"$TOMCAT_GROUP" \
        "$TOMCAT_INSTALL_DIR"/webapps \
        "$TOMCAT_INSTALL_DIR"/work \
        "$TOMCAT_INSTALL_DIR"/temp \
        "$TOMCAT_INSTALL_DIR"/logs \
        "$TOMCAT_INSTALL_DIR"/bin || log_error "Failed to set ownership on Tomcat subdirectories."
    sudo chmod +x "$TOMCAT_INSTALL_DIR"/bin/*.sh || log_error "Failed to set execute permissions on Tomcat scripts."

    # Create Systemd Service File
    log_info "Creating systemd service file for Tomcat 9 at /etc/systemd/system/tomcat9.service..."
    sudo bash -c "cat > /etc/systemd/system/tomcat9.service" <<EOF
[Unit]
Description=Apache Tomcat Web Application Container
After=network.target

[Service]
Type=forking
User=${TOMCAT_USER}
Group=${TOMCAT_GROUP}
Environment=JAVA_HOME=${JAVA_HOME_PATH}
Environment=CATALINA_PID=${TOMCAT_INSTALL_DIR}/temp/tomcat.pid
Environment=CATALINA_HOME=${TOMCAT_INSTALL_DIR}
Environment=CATALINA_BASE=${TOMCAT_INSTALL_DIR}
Environment=GUACAMOLE_HOME=/etc/guacamole # <-- Guacamole's config directory
ExecStart=${TOMCAT_INSTALL_DIR}/bin/startup.sh
ExecStop=${TOMCAT_INSTALL_DIR}/bin/shutdown.sh
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    log_info "Reloading systemd, enabling and starting Tomcat 9..."
    sudo systemctl daemon-reload || log_error "Failed to reload systemd daemon after Tomcat service creation."
    sudo systemctl enable tomcat9 || log_error "Failed to enable Tomcat 9 service."
    sudo systemctl start tomcat9 || log_error "Failed to start Tomcat 9. Check logs (journalctl -xeu tomcat9)."
    log_info "Tomcat 9 setup complete and running."

    # Configure Tomcat Manager/Admin user
    log_info "Configuring Tomcat Manager/Admin user in tomcat-users.xml..."
    sudo cp "$TOMCAT_INSTALL_DIR"/conf/tomcat-users.xml "$TOMCAT_INSTALL_DIR"/conf/tomcat-users.xml.bak
    sudo sed -i '/<\/tomcat-users>/i\
  <role rolename="manager-gui"/>\
  <role rolename="admin-gui"/>\
  <user username="'"${TOMCAT_ADMIN_USER}"'" password="'"${TOMCAT_ADMIN_PASSWORD}"'" roles="manager-gui,admin-gui"/>' \
  "$TOMCAT_INSTALL_DIR"/conf/tomcat-users.xml
    sudo sed -i '/RemoteAddrValve/d' /opt/tomcat/webapps/docs/META-INF/context.xml
    sudo sed -i '/RemoteAddrValve/d' /opt/tomcat/webapps/manager/META-INF/context.xml
    sudo sed -i '/RemoteAddrValve/d' /opt/tomcat/webapps/host-manager/META-INF/context.xml
    log_info "Tomcat Manager user added. Remember to change the password."
}

deploy_guacamole_war() {
    log_info "Deploying guacamole.war to Tomcat's webapps directory..."
    # Move WAR to Tomcat's webapps directory
    sudo cp "$SCRIPT_DIR/$GUAC_WAR" "${TOMCAT_INSTALL_DIR}/webapps/guacamole.war" || log_error "Failed to deploy guacamole.war."
    sudo chown "${TOMCAT_USER}":"${TOMCAT_GROUP}" "${TOMCAT_INSTALL_DIR}/webapps/guacamole.war" || log_error "Failed to set ownership for guacamole.war."
    log_info "guacamole.war deployed."
}

setup_postgresql_database() {
    log_info "Setting up PostgreSQL database for Guacamole..."

    # Configure 'postgres' user password
    log_info "Setting password for PostgreSQL 'postgres' superuser (if not set)..."
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$POSTGRES_ROOT_PASSWORD';" || log_error "Failed to set PostgreSQL root password."
    sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses TO '*';" || log_error "Failed to set PostgreSQL listen_addresses."
	sudo sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/g" /etc/postgresql/*/main/postgresql.conf || log_error "Failed to set PostgreSQL listen_addresses in postgresql.conf."
	sudo sed -i "s/^host[[:space:]]*all[[:space:]]*all[[:space:]]*127.0.0.1\/32[[:space:]]*scram-sha-256/host    all    all    0.0.0.0\/0    scram-sha-256/" /etc/postgresql/*/main/pg_hba.conf || log_error "Failed to set PostgreSQL host in pg_hba.conf."
    # Create Guacamole database and user
    log_info "Creating Guacamole database ($POSTGRESQL_GUAC_DB_NAME) and user ($POSTGRESQL_GUAC_DB_USER)..."
    sudo -u postgres psql <<EOF || log_error "Failed to create PostgreSQL database/user."
CREATE DATABASE "$POSTGRESQL_GUAC_DB_NAME";
CREATE USER "$POSTGRESQL_GUAC_DB_USER" WITH PASSWORD '$POSTGRES_ROOT_PASSWORD';
EOF

    log_info "PostgreSQL database and user created."

    log_info "Installing Guacamole JDBC extension for PostgreSQL..."
    local GUAC_JDBC_DIR="/tmp/guacamole-auth-jdbc"
	sudo mkdir -p "$GUAC_JDBC_DIR"
    sudo tar -xzf "$SCRIPT_DIR/$GUAC_JDBC_TAR" --strip-components=1 -C "$GUAC_JDBC_DIR" || log_error "Failed to extract JDBC extension."

    sudo mkdir -p /etc/guacamole/extensions || log_error "Failed to create /etc/guacamole/extensions."
    sudo mkdir -p /etc/guacamole/lib || log_error "Failed to create /etc/guacamole/lib."

    # Copy PostgreSQL JDBC extension JAR
    sudo cp "$GUAC_JDBC_DIR/postgresql/guacamole-auth-jdbc-postgresql-1.5.5.jar" /etc/guacamole/extensions/ || log_error "Failed to copy PostgreSQL JDBC extension."

    # Copy PostgreSQL JDBC driver (should be included in the JDBC extension tarball)
    sudo cp "$SCRIPT_DIR/$POSTGRESQL_JDBC_JAR" /etc/guacamole/lib/

    log_info "Initializing Guacamole database schema (PostgreSQL)..."
    # Execute all SQL schema files in order
    local SCHEMA_DIR="$GUAC_JDBC_DIR/postgresql/schema"
    for sql_file in "$SCHEMA_DIR"/*.sql; do
        log_info "Executing schema file: $(basename "$sql_file")..."
        sudo -u postgres psql "$POSTGRESQL_GUAC_DB_NAME" < "$sql_file" || log_error "Failed to execute SQL schema file: $sql_file."
    done
	
    # Grant full access for the new user to Guacamole database
    log_info "Granting full access for ($POSTGRESQL_GUAC_DB_USER) on ($POSTGRESQL_GUAC_DB_NAME)..."
    sudo -u postgres psql -d "$POSTGRESQL_GUAC_DB_NAME" <<EOF || log_error "Failed to grant PostgreSQL database access to user."
GRANT ALL PRIVILEGES ON DATABASE "$POSTGRESQL_GUAC_DB_NAME" TO "$POSTGRESQL_GUAC_DB_USER";
GRANT ALL PRIVILEGES ON SCHEMA public TO "$POSTGRESQL_GUAC_DB_USER";
GRANT USAGE ON SCHEMA public TO "$POSTGRESQL_GUAC_DB_USER";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$POSTGRESQL_GUAC_DB_USER";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$POSTGRESQL_GUAC_DB_USER";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$POSTGRESQL_GUAC_DB_USER";
EOF
    log_info "Database schema initialized."
}

configure_guacamole_properties() {
    log_info "Creating guacamole.properties file in /etc/guacamole/..."
    sudo bash -c "cat > /etc/guacamole/guacamole.properties" <<EOF || log_error "Failed to write guacamole.properties."
# Hostname and port of guacamole proxy (guacd)
guacd-hostname: localhost
guacd-port: 4822

# PostgreSQL properties
postgresql-hostname: localhost
postgresql-port: 5432
postgresql-database: $POSTGRESQL_GUAC_DB_NAME
postgresql-username: $POSTGRESQL_GUAC_DB_USER
postgresql-password: $POSTGRES_ROOT_PASSWORD
EOF

    # Set correct permissions for the Guacamole configuration directory
    # GUACAMOLE_HOME will be /etc/guacamole, which is read by Tomcat
    log_info "Setting ownership and permissions for /etc/guacamole..."
    sudo chown -R "$TOMCAT_USER":"$TOMCAT_GROUP" /etc/guacamole || log_error "Failed to set ownership for /etc/guacamole."
    sudo chmod -R 0755 /etc/guacamole || log_error "Failed to set permissions for /etc/guacamole."
    log_info "guacamole.properties configured and permissions set."
}

adjust_firewall() {
    log_info "Adjusting firewall (UFW) to allow access to Guacamole (port 8080) and Guacd (port 4822) and PostgreSQL (port 5432)..."
    if command_exists ufw; then
        sudo ufw allow 8080/tcp || log_error "Failed to add UFW rule for port 8080."
        sudo ufw allow 4822/tcp || log_error "Failed to add UFW rule for port 4822."
        sudo ufw allow 5432/tcp || log_error "Failed to add UFW rule for port 5432."
        sudo ufw reload || log_error "Failed to reload UFW."
        log_info "UFW rules applied."
    else
        log_info "UFW not found. Skipping firewall configuration. Please configure your firewall manually if needed."
    fi
}

restart_all_services() {
    log_info "Restarting Guacamole and Tomcat services to apply changes..."
    sudo systemctl restart guacd || log_error "Failed to restart guacd."
    sudo systemctl restart tomcat9 || log_error "Failed to restart tomcat9."
    sudo systemctl restart postgresql || log_error "Failed to restart postgresql."
    log_info "All services restarted."
}

# --- Main Script Execution Flow ---

log_info "Starting comprehensive Guacamole installation with PostgreSQL and Tomcat 9 (manual)."

install_system_dependencies
setup_guacd
setup_tomcat9_manual # Install and configure Tomcat 9
deploy_guacamole_war
setup_postgresql_database
configure_guacamole_properties
adjust_firewall
restart_all_services

log_info "----------------------------------------------------------------------------"
log_info "Installation process complete!"

log_info "Tomcat is running at: http://YOUR_SERVER_IP:8080/manager/"
log_info "Tomcat default login: ${TOMCAT_ADMIN_USER} / ${TOMCAT_ADMIN_PASSWORD} (Feel free to change it)"

log_info "Guacd is running at port: tcp://YOUR_SERVER_IP:4822"
log_info "Guacamole is running at: http://YOUR_SERVER_IP:8080/guacamole/"
log_info "Guacamole default login: guacadmin / 4A3C5CE6-D151-4DF7-B256-B377FEE62170 (If you change it you need to change it too in LEDR Api configurations)"

log_info "PostgreSQL is running at port: tcp://YOUR_SERVER_IP:5432"
log_info "PostgreSQL default login: postgres / ${POSTGRES_ROOT_PASSWORD} (Feel free to change it)"
log_info "PostgreSQL Guacamole DB login: ${POSTGRESQL_GUAC_DB_USER} / ${POSTGRES_ROOT_PASSWORD} (If you change it you need to change it too in Guacamole server configurations)"