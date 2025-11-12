FROM fedora:40

# Set working directory
WORKDIR /app

# Install Python, pip, and build dependencies
RUN dnf install -y \
    python3 \
    python3-pip \
    python3-devel \
    gcc \
    gcc-c++ \
    rust \
    cargo \
    && dnf clean all

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip3 install --no-cache-dir -r requirements.txt

# Copy application files
COPY ops_incident_assistant.py .
COPY mcp_http_client.py .

# Expose port
EXPOSE 5678

# Run the application
CMD ["python3", "ops_incident_assistant.py"]

