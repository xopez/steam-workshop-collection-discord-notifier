#!/bin/bash

WORKSHOP_COLLECTION_ID="12334567890"                              # Replace with your Workshop Collection ID
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/XXXX/XXXXX" # Replace with your Discord Webhook URL
# Dependencies: jq, curl
ITEMS_DATA_FILE="workshop_items.json"

# Fetch item details (including preview_url, only one API request per function)
fetch_items_details() {
    children_json=$(curl -s -X POST "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/" \
        -d "collectioncount=1" -d "publishedfileids[0]=$WORKSHOP_COLLECTION_ID")
    ids=("$(echo "$children_json" | jq -r '.response.collectiondetails[0].children[].publishedfileid')")
    itemcount=${#ids[@]}

    post_data="-d itemcount=$itemcount"
    for i in "${!ids[@]}"; do
        post_data+=" -d publishedfileids[$i]=${ids[$i]}"
    done

    details_json=$(eval curl -s -X POST "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" $post_data)
    echo "$details_json" | jq '[.response.publishedfiledetails[] | {id: .publishedfileid, title: .title, updated: .time_updated}]'
}

send_discord_updates() {
    new_json=$(fetch_items_details)

    if [ ! -f "$ITEMS_DATA_FILE" ]; then
        echo "$new_json" >"$ITEMS_DATA_FILE"
        return
    fi

    # Compare old/new in jq (new or changed items)
    updates=$(jq -n \
        --slurpfile old "$ITEMS_DATA_FILE" \
        --slurpfile new <(echo "$new_json") '
        [ $new[0][] as $n |
          ($old[0][] | select(.id == $n.id)) as $o |
          select(($o == null) or ($o.updated != $n.updated or $o.title != $n.title)) |
          {id: $n.id, newtitle: $n.title, oldtitle: ($o.title // null), updated: $n.updated, oldupdated: ($o.updated // null)}
        ]')

    echo "$updates" | jq -rc '.[] | {id, newtitle, oldtitle, updated, oldupdated, url: ("https://steamcommunity.com/sharedfiles/filedetails/?id=" + .id)}' |
        while read -r item; do
            id=$(echo "$item" | jq -r '.id')
            title=$(echo "$item" | jq -r '.newtitle')
            oldtitle=$(echo "$item" | jq -r '.oldtitle')
            updated=$(echo "$item" | jq -r '.updated')
            oldupdated=$(echo "$item" | jq -r '.oldupdated')
            url=$(echo "$item" | jq -r '.url')
            # Fetch preview image (now here, not in the JSON)
            preview_url=$(curl -s "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
                -d itemcount=1 -d publishedfileids[0]="$id" | jq -r '.response.publishedfiledetails[0].preview_url')
            # Placeholder for missing values
            if [ "$title" = "null" ] || [ -z "$title" ]; then
                title="Unknown"
            fi
            if [ "$updated" = "null" ] || [ -z "$updated" ]; then
                updated_en="Unknown"
            else
                updated_en=$(date -d @"$updated" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$updated" '+%Y-%m-%d %H:%M')
            fi
            # Change description
            changes=""
            if [ "$title" != "$oldtitle" ] && [ "$updated" != "$oldupdated" ]; then
                changes="✏️ Title changed & new update published."
            elif [ "$title" != "$oldtitle" ]; then
                changes="✏️ Title changed."
            elif [ "$updated" != "$oldupdated" ]; then
                changes="🆕 New update published."
            else
                changes="🆕 First time detection or incomplete comparison data."
            fi

            embed_json=$(jq -n --arg title "$title" --arg url "$url" --arg img "$preview_url" --arg updated "$updated_en" --arg changes "$changes" '{embeds: [{
            title: $title,
            thumbnail: {url: $img},
            fields: [
                {name: "\uD83D\uDD52 Last Update", value: $updated, inline: true},
                {name: "\uD83D\uDD17 Workshop Link", value: $url, inline: false},
                {name: "\u2139\uFE0F Change", value: $changes, inline: false}
            ]
        }]}')
            curl -s -H "Content-Type: application/json" -X POST \
                -d "$embed_json" "$DISCORD_WEBHOOK_URL" >/dev/null
        done

    echo "$new_json" >"$ITEMS_DATA_FILE"
}

send_discord_updates
