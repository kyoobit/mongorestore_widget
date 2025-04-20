FROM debian:bookworm-slim

# Install dependencies
# NOTE: MongoDB does not support a separate Debian repo, use Ubuntu Jammy instead
RUN apt-get update && \
    apt-get install --yes curl gnupg2 ca-certificates rclone && \
    curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.0.list && \
    apt-get update && \
    apt-get install -y mongodb-database-tools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the restore script
COPY restore.sh /usr/local/bin/restore.sh
RUN chmod +x /usr/local/bin/restore.sh

# Run the restore script
ENTRYPOINT ["/usr/local/bin/restore.sh"]
