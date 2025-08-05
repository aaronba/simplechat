# Builder stage: install dependencies in a virtualenv
FROM cgr.dev/chainguard/python:latest-dev AS builder

WORKDIR /app

# Create a Python virtual environment
RUN python -m venv /app/venv

# Copy requirements and install them into the virtualenv
COPY requirements-simple-test.txt requirements.txt
ENV PATH="/app/venv/bin:$PATH"
RUN pip install --no-cache-dir -r requirements.txt

# Production stage: minimal runtime image
FROM cgr.dev/chainguard/python:latest

WORKDIR /app

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PATH="/app/venv/bin:$PATH"
ENV PYTHONPATH="/app/venv/lib/python3.11/site-packages:/app"

# Copy application code and set ownership
COPY --chown=nonroot:nonroot . ./

# Copy the virtualenv from the builder stage
COPY --from=builder --chown=nonroot:nonroot /app/venv /app/venv

# Expose port (if needed for web interface)
EXPOSE 8000

# Use nonroot user for security
USER nonroot:nonroot

# Default command - run the main test script
ENTRYPOINT ["/app/venv/bin/python3"]
CMD ["simple_hybrid_test.py"]
