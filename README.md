# Steam Workshop Collection Notifier to Discord

This script monitors a Steam Workshop Collection and sends notifications about updates or changes of individual items directly to a Discord channel via webhook.

## Features

- Monitors a Steam Workshop Collection for new or changed items
- Sends structured Discord messages with title, preview image, change description, and workshop item link
- Detects title changes and updates of individual items
- Stores the last state locally to only report new changes

## Requirements

- [jq](https://stedolan.github.io/jq/)
- [curl](https://curl.se/)

Install dependencies (example for Ubuntu/Debian):
```sh
sudo apt-get install jq curl
```

## Setup

1. **Clone the repository:**
    ```sh
    git clone https://github.com/your-username/steam-workshop-collection-notifier-to-discord.git
    cd steam-workshop-collection-notifier-to-discord
    ```

2. **Configure:**
    - Open [`workshop_updates.sh`](workshop_updates.sh)
    - Set your Workshop Collection ID:
      ```bash
      WORKSHOP_COLLECTION_ID="YOUR_COLLECTION_ID"
      ```
    - Set your Discord Webhook URL:
      ```bash
      DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
      ```

3. **Make the script executable:**
    ```sh
    chmod +x workshop_updates.sh
    ```

4. **Run the script:**
    ```sh
    ./workshop_updates.sh
    ```

## Automation (optional)

To run the script regularly, you can set up a cronjob:
```sh
crontab -e
```
Add a line like this to check every 30 minutes:
```
*/30 * * * * /path/to/your/repo/workshop_updates.sh
```

## Notes

- On the first run, a file `workshop_items.json` is created to store the current state.
- Only new or changed items are reported to Discord.
- The script can be run as often as you like.

## Example `workshop_items.json`

This file is created automatically and stores the last known state of your collection:

```json
[
  {
    "id": "123456789",
    "title": "Example Workshop Item",
    "updated": 1712345678
  },
  {
    "id": "987654321",
    "title": "Another Item",
    "updated": 1712345689
  }
]
```

## License

MIT License

---
