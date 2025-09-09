#!/usr/bin/env python3
import subprocess
import requests
import json
import os
SEEN_FILE = os.getenv("SEEN_FILE", ".sent_notifications")

def load_seen_ids():
    if not os.path.exists(SEEN_FILE):
        return set()
    with open(SEEN_FILE, "r") as f:
        return set(line.strip() for line in f if line.strip())

def save_seen_id(notification_id):
    with open(SEEN_FILE, "a") as f:
        f.write(notification_id + "\n")

# Discord webhook URL
DISCORD_WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL", "https://discord.com/api/webhooks/abcd1234")
# Path to tbot-issued identity file
IDENTITY = os.getenv("TELEPORT_IDENTITY", "/opt/machine-id/identity")
# Teleport Tenant FQDN
TENANT_FQDN = os.getenv("TELEPORT_AUTH", "mytenant.teleport.sh")
def get_notifications():
    print("Running tctl to fetch notifications...")
    try:
        result = subprocess.run(
            [
                "tctl",
                "--identity", IDENTITY,
                "--auth-server", TENANT_FQDN,
                "notifications", "ls",
                "--format=json"
            ],
            capture_output=True, text=True, check=True
        )
        print("📥 Raw tctl output:")
        print(result.stdout)
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print("Error running tctl:", e.stderr)
        return []

def send_to_discord(title, labels):
    content = (
        f"📢 **Teleport Cluster Upgrade Notification**\n"
        f"**Title:** {title}\n"
        f"**Tenant:** `{AUTH_FQDN}`\n"
    )
    if "teleport.internal/content" in labels:
        content += f"**Details:** {labels['teleport.internal/content']}"
    payload = {"content": content}
    response = requests.post(DISCORD_WEBHOOK_URL, json=payload)
    print(f"Discord response: {response.status_code} {response.text}")
    if response.status_code != 204:
        print("Discord webhook failed")

def main():
    print("Starting Teleport upgrade notifier...")
    seen_ids = load_seen_ids()
    notifications = get_notifications()
    print(f"🔍 Found {len(notifications)} notifications")

    for note in notifications:
        note_id = note.get("metadata", {}).get("name", "")
        labels = note.get("metadata", {}).get("labels", {})
        title = labels.get("teleport.internal/title", "")

        if "Teleport Cluster Upgrade" in title:
            if note_id in seen_ids:
                print(f"Already sent: {note_id}")
                continue
            print(f"New upgrade notification: {title}")
            send_to_discord(title, labels)
            save_seen_id(note_id)
        else:
            print("⏭️ Skipping:", title)

if __name__ == "__main__":
    main()
