This script will check output of tctl notifications ls and look for "**Teleport Cluster Upgrade Notification**" if found it will send notification to a Discord webhook with the notification, version, and tenant FQDN.

**Requires**

A Discord Webhook (https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks)
A working tbot installation that outputs machine identity (https://goteleport.com/docs/machine-workload-identity/machine-id/getting-started/)
A role associated with your tbot that permits read and list verbs on the notification resource

*You will need to*
Edit DISCORD_WEBHOOK_URL with the webhook URL 

Edit TENANT_FQDN with the fqdn of your Teleport tenant (eg mytenant.teleport.sh)

If your tbot install doesn't output machine identity to /opt/machine-id/identity you will need to change IDENTITY as well 

