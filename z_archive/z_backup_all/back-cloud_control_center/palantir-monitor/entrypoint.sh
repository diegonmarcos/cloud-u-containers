#!/bin/bash
#
# Palantir Monitor Entrypoint
# Fixes SSH key permissions before running checks
#

# Copy OCI SSH key if mounted read-only and fix permissions
if [[ -f /root/.ssh/id_rsa ]]; then
    cp /root/.ssh/id_rsa /tmp/ssh_key_oci
    chmod 600 /tmp/ssh_key_oci
    export SSH_KEY_OCI=/tmp/ssh_key_oci
else
    echo "[WARN] No OCI SSH key found at /root/.ssh/id_rsa"
fi

# Copy GCP SSH key if mounted read-only and fix permissions
if [[ -f /root/.ssh/google_compute_engine ]]; then
    cp /root/.ssh/google_compute_engine /tmp/ssh_key_gcp
    chmod 600 /tmp/ssh_key_gcp
    export SSH_KEY_GCP=/tmp/ssh_key_gcp
else
    echo "[WARN] No GCP SSH key found at /root/.ssh/google_compute_engine"
fi

# Execute the command
exec "$@"
