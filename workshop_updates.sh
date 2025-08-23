#!/bin/bash

# Steam Workshop Collection to JSON Converter (Optimized)
# Loads all items from a Steam Workshop Collection and saves them to a local JSON file

# --- Configuration ---
COLLECTION_ID=""
OUTPUT_FILE="steam_collection.json"
BATCH_SIZE=20
MAX_PARALLEL=10
DISCORD_WEBHOOK_URL=""
MAX_DISCORD_EMBEDS=10
CURL_TIMEOUT=30
SCRAPING_DELAY=0.5

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Help Function ---
show_help() {
    cat <<EOF
Usage: $0 -c COLLECTION_ID [-o OUTPUT_FILE] [-b BATCH_SIZE] [-w WEBHOOK_URL]

Options:
  -c COLLECTION_ID  Steam Workshop Collection ID (required)
  -o OUTPUT_FILE    Output JSON file (default: steam_collection.json)
  -b BATCH_SIZE     Batch size for API requests (default: 20, max: 50)
  -w WEBHOOK_URL    Discord webhook URL for notifications (optional)
  -h                Show this help

Example:
  $0 -c 123456789 -o my_collection.json -b 30 -w https://discord.com/api/webhooks/...
EOF
}

# --- Parse parameters ---
while getopts "c:o:b:w:h" opt; do
    case $opt in
    c) COLLECTION_ID="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    b)
        BATCH_SIZE="$OPTARG"
        if ! [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || [ "$BATCH_SIZE" -gt 50 ] || [ "$BATCH_SIZE" -lt 1 ]; then
            echo -e "${RED}Error: Batch size must be between 1 and 50${NC}\n"
            show_help
            exit 1
        fi
        ;;
    w) DISCORD_WEBHOOK_URL="$OPTARG" ;;
    h)
        show_help
        exit 0
        ;;
    *)
        echo "Invalid option: -$OPTARG" >&2
        show_help
        exit 1
        ;;
    esac
done

# --- Dependency Check Function ---
check_dependencies() {
    local missing_deps=()

    # Check for required dependencies
    if ! command -v curl &>/dev/null; then
        missing_deps+=("curl")
    fi

    if ! command -v jq &>/dev/null; then
        missing_deps+=("jq")
    fi

    # Check for date command (should be available on most systems)
    if ! command -v date &>/dev/null; then
        missing_deps+=("date")
    fi

    # Check for mktemp command
    if ! command -v mktemp &>/dev/null; then
        missing_deps+=("mktemp")
    fi

    # Report missing required dependencies
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing required dependencies:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo -e "${RED}  - $dep${NC}"
        done
        echo ""
        echo -e "${YELLOW}Installation instructions:${NC}"
        echo -e "${YELLOW}  Ubuntu/Debian: sudo apt install ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}  CentOS/RHEL:   sudo yum install ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}  Fedora:        sudo dnf install ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}  macOS:         brew install ${missing_deps[*]}${NC}"
        exit 1
    fi
}

# --- Preflight Checks ---
check_dependencies

[ -z "$COLLECTION_ID" ] && {
    echo -e "${RED}Error: Collection ID is required${NC}"
    show_help
    exit 1
}
[[ ! "$COLLECTION_ID" =~ ^[0-9]+$ ]] && {
    echo -e "${RED}Error: Collection ID must be numeric${NC}\n"
    show_help
    exit 1
}

# --- Main ---
echo -e "${GREEN}Loading Steam Workshop Collection ID: $COLLECTION_ID${NC}"
COLLECTION_URL="https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/"
echo -e "${YELLOW}Sending API request...${NC}"
if ! RESPONSE=$(curl -s -m "$CURL_TIMEOUT" -X POST -H "Content-Type: application/x-www-form-urlencoded" -d "collectioncount=1&publishedfileids[0]=$COLLECTION_ID" "$COLLECTION_URL"); then
    echo -e "${RED}Error fetching collection details${NC}"
    exit 1
fi

if echo "$RESPONSE" | grep -q '"result":1'; then
    COLLECTION_NAME=$(echo "$RESPONSE" | jq -r '.response.collectiondetails[0].title' 2>/dev/null)
    [ -n "$COLLECTION_NAME" ] && [ "$COLLECTION_NAME" != "null" ] &&
        echo -e "${GREEN}Collection details successfully retrieved: \"$COLLECTION_NAME\"${NC}" ||
        echo -e "${GREEN}Collection details successfully retrieved${NC}"
else
    if echo "$RESPONSE" | grep -q '"result":9'; then
        echo -e "${RED}Error: Steam Workshop Collection with ID $COLLECTION_ID not found${NC}\n${RED}Please verify that the Collection ID is correct${NC}"
    elif echo "$RESPONSE" | grep -q '"result":15'; then
        echo -e "${RED}Error: Steam Workshop Collection is private or unavailable${NC}"
    elif [ -z "$RESPONSE" ] || echo "$RESPONSE" | grep -q "error"; then
        echo -e "${RED}Error: Steam API is unreachable or not responding${NC}\n${RED}Please try again later${NC}"
    else
        echo -e "${RED}Error: Unknown API error for Collection ID $COLLECTION_ID${NC}\n${RED}API Response: $RESPONSE${NC}"
    fi
    exit 1
fi

WORKSHOP_ITEMS=$(echo "$RESPONSE" | jq -r '.response.collectiondetails[0].children[]?.publishedfileid' 2>/dev/null)
[ -z "$WORKSHOP_ITEMS" ] && {
    echo -e "${RED}No workshop items found in collection${NC}"
    exit 1
}
ITEM_COUNT=$(echo "$WORKSHOP_ITEMS" | wc -l)
echo -e "${GREEN}$ITEM_COUNT workshop items found${NC}"
mapfile -t ITEMS_ARRAY < <(echo "$WORKSHOP_ITEMS")

# --- Backup ---
OLD_OUTPUT_FILE="${OUTPUT_FILE}.old"
if [ -f "$OUTPUT_FILE" ]; then
    echo -e "${YELLOW}Creating backup of existing file...${NC}"
    mv "$OUTPUT_FILE" "$OLD_OUTPUT_FILE"
else
    echo -e "${GREEN}First run detected - no previous data file found${NC}"
fi

# --- Temp Directory ---
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- Utility Functions ---
get_timezone() {
    local month="$1" day="$2"

    # Convert month name to number efficiently
    case "$month" in
    Jan) local month_num=1 ;;
    Feb) local month_num=2 ;;
    Mar) local month_num=3 ;;
    Apr | May | Jun | Jul | Aug | Sep)
        echo "PDT"
        return
        ;;
    Oct) local month_num=10 ;;
    Nov) local month_num=11 ;;
    Dec)
        echo "PST"
        return
        ;;
    *)
        echo "PST"
        return
        ;;
    esac

    # Handle DST transition months
    case "$month_num" in
    3) [ "$day" -ge 8 ] && echo "PDT" || echo "PST" ;;
    10 | 11) [ "$month_num" -eq 11 ] && [ "$day" -gt 7 ] && echo "PST" || echo "PDT" ;;
    *) echo "PST" ;;
    esac
}
escape_json() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'; }

send_discord_notification() {
    [ -z "$DISCORD_WEBHOOK_URL" ] && return 0
    local embeds_json="$1"
    local payload
    payload=$(
        cat <<EOF
{"content": null, "embeds": $embeds_json, "username": "Steam Workshop Monitor"}
EOF
    )
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1
    return $?
}

create_item_embed() {
    local item_id="$1" title="$2" change_type="$3" old_time="$4" new_time="$5" color="$6" old_title="$7" preview_url="$8"
    local title_escaped
    title_escaped=$(escape_json "$title")
    local url="https://steamcommunity.com/sharedfiles/filedetails/?id=$item_id"
    local old_time_str="Unknown" new_time_str="Unknown"
    if [ "$old_time" != "null" ] && [ -n "$old_time" ]; then
        local old_utc old_local
        old_utc=$(date -d "@$old_time" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "Invalid")
        old_local=$(date -d "@$old_time" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
        if [ -n "$old_local" ] && [ "$old_local" != "Invalid" ]; then
            old_time_str="$old_utc ($old_local)"
        else
            old_time_str="$old_utc"
        fi
    fi
    if [ "$new_time" != "null" ] && [ -n "$new_time" ]; then
        local new_utc new_local
        new_utc=$(date -d "@$new_time" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "Invalid")
        new_local=$(date -d "@$new_time" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
        if [ -n "$new_local" ] && [ "$new_local" != "Invalid" ]; then
            new_time_str="$new_utc ($new_local)"
        else
            new_time_str="$new_utc"
        fi
    fi
    local description=""
    case "$change_type" in
    listed) description="✅ **Item became publicly listed**\\n\\n🔗 [View on Steam Workshop]($url)" ;;
    unlisted) description="🔒 **Item became unlisted/private**\\n\\n🔗 [View on Steam Workshop]($url)" ;;
    removed) description="❌ **Item removed from collection**\\n\\n🔗 [View on Steam Workshop]($url)" ;;
    new) description="📦 **New item added to collection**\\n\\n🔗 [View on Steam Workshop]($url)" ;;
    updated) description="🔄 **Item updated**\\n\\n⏰ **Previous:** $old_time_str\\n⏰ **Current:** $new_time_str\\n\\n🔗 [View on Steam Workshop]($url)" ;;
    unavailable) description="💀 **Item became unavailable**\\n\\n🔗 [View on Steam Workshop]($url)" ;;
    title_changed)
        local old_title_escaped
        old_title_escaped=$(escape_json "$old_title")
        description="📝 **Title changed**\\n\\n📋 **Previous:** $old_title_escaped\\n📋 **Current:** $title_escaped\\n\\n🔗 [View on Steam Workshop]($url)"
        ;;
    title_and_update)
        local old_title_escaped
        old_title_escaped=$(escape_json "$old_title")
        description="🔄📝 **Title and content updated**\\n\\n📋 **Previous Title:** $old_title_escaped\\n📋 **Current Title:** $title_escaped\\n\\n⏰ **Previous Update:** $old_time_str\\n⏰ **Current Update:** $new_time_str\\n\\n🔗 [View on Steam Workshop]($url)"
        ;;
    esac
    local embed_json
    embed_json=$(
        cat <<EOF
{"title": "$title_escaped", "description": "$description", "color": $color, "footer": {"text": "Item ID: $item_id"}, "timestamp": "$(date -Iseconds)"
EOF
    )
    if [ -n "$preview_url" ] && [ "$preview_url" != "null" ]; then embed_json="$embed_json,\"thumbnail\":{\"url\":\"$preview_url\"}"; fi
    embed_json="$embed_json}"
    echo "$embed_json"
}

# Function to detect and report changes
detect_changes() {
    local new_file="$1"
    local old_file="$2"

    # Arrays to store changes
    local new_items=()
    local updated_items=()
    local removed_items=()
    local listed_items=()
    local unlisted_items=()
    local unavailable_items=()
    local title_changed_items=()
    local title_and_update_items=()

    echo -e "${YELLOW}Detecting changes...${NC}"

    # If old file doesn't exist, this is the first run - skip notifications
    if [ ! -f "$old_file" ]; then
        echo -e "${GREEN}No previous data found - this is the first run, skipping notifications${NC}"
        return 0
    fi

    # Create associative arrays for comparison
    local temp_old="$TEMP_DIR/old_items.tmp"
    local temp_new="$TEMP_DIR/new_items.tmp"

    # Extract items with all relevant fields
    jq -r '.items[] | "\(.publishedfileid)§\(.time_updated)§\(.title)§\(.data_source)"' "$old_file" >"$temp_old" 2>/dev/null
    jq -r '.items[] | "\(.publishedfileid)§\(.time_updated)§\(.title)§\(.data_source)"' "$new_file" >"$temp_new" 2>/dev/null

    # Find new items (completely new to collection)
    while IFS='§' read -r id new_time title data_source; do
        if ! grep -q "^$id§" "$temp_old" 2>/dev/null; then
            new_items+=("$id§$new_time§$title§$data_source")
        fi
    done <"$temp_new"

    # Find removed items (no longer in collection)
    while IFS='§' read -r id old_time title data_source; do
        if ! grep -q "^$id§" "$temp_new" 2>/dev/null; then
            removed_items+=("$id§$old_time§$title§$data_source")
        fi
    done <"$temp_old"

    # Find changed items (existing items with modifications)
    while IFS='§' read -r id new_time new_title new_data_source; do
        local old_line
        old_line=$(grep "^$id§" "$temp_old" 2>/dev/null)
        if [ -n "$old_line" ]; then
            IFS='§' read -r _ old_time old_title old_data_source <<<"$old_line"

            local time_changed=false
            local title_changed=false
            local data_source_changed=false

            # Check for changes
            if [ "$old_time" != "$new_time" ] && [ "$new_time" != "null" ] && [ "$old_time" != "null" ]; then
                time_changed=true
            fi

            if [ "$old_title" != "$new_title" ]; then
                title_changed=true
            fi

            if [ "$old_data_source" != "$new_data_source" ]; then
                data_source_changed=true
            fi

            # Categorize changes based on data_source transitions
            if [ "$data_source_changed" = true ]; then
                case "$old_data_source->$new_data_source" in
                "scraped->api" | "null->api" | "unavailable->api" | "unavailable->scraped")
                    listed_items+=("$id§$new_time§$new_title§$old_data_source§$new_data_source")
                    ;;
                "api->scraped")
                    if [ "$new_title" = "Steam Community :: Error" ]; then
                        unavailable_items+=("$id§$new_time§$old_title§$old_data_source§$new_data_source")
                    else
                        unlisted_items+=("$id§$new_time§$new_title§$old_data_source§$new_data_source")
                    fi
                    ;;
                "api->unavailable" | "scraped->unavailable")
                    unavailable_items+=("$id§$new_time§$old_title§$old_data_source§$new_data_source")
                    ;;
                "*->null" | "api->null" | "scraped->null" | "unavailable->null")
                    unavailable_items+=("$id§$new_time§$old_title§$old_data_source§$new_data_source")
                    ;;
                "*->scraped")
                    if [ "$old_data_source" != "api" ] && [ "$old_data_source" != "unavailable" ]; then
                        if [ "$new_title" = "Steam Community :: Error" ]; then
                            unavailable_items+=("$id§$new_time§$old_title§$old_data_source§$new_data_source")
                        else
                            unlisted_items+=("$id§$new_time§$new_title§$old_data_source§$new_data_source")
                        fi
                    fi
                    ;;
                "*->unavailable")
                    unavailable_items+=("$id§$new_time§$old_title§$old_data_source§$new_data_source")
                    ;;
                esac
            # Handle content changes (same data_source)
            elif [ "$time_changed" = true ] && [ "$title_changed" = true ]; then
                if [ "$new_title" = "Steam Community :: Error" ]; then
                    unavailable_items+=("$id§$new_time§$old_title§$new_data_source§$new_data_source")
                else
                    title_and_update_items+=("$id§$old_time§$new_time§$old_title§$new_title§$new_data_source")
                fi
            elif [ "$time_changed" = true ]; then
                updated_items+=("$id§$old_time§$new_time§$new_title§$new_data_source")
            elif [ "$title_changed" = true ]; then
                if [ "$new_title" = "Steam Community :: Error" ]; then
                    unavailable_items+=("$id§$new_time§$old_title§$new_data_source§$new_data_source")
                else
                    title_changed_items+=("$id§$old_title§$new_title§$new_data_source")
                fi
            fi
        fi
    done <"$temp_new"

    # Report changes to console
    local total_changes=$((${#new_items[@]} + ${#updated_items[@]} + ${#removed_items[@]} + ${#listed_items[@]} + ${#unlisted_items[@]} + ${#unavailable_items[@]} + ${#title_changed_items[@]} + ${#title_and_update_items[@]}))

    if [ $total_changes -eq 0 ]; then
        echo -e "${GREEN}No changes detected${NC}"
        return 0
    fi

    echo -e "${GREEN}Changes detected: $total_changes total${NC}"
    echo ""

    # Report individual changes to console
    for item in "${new_items[@]}"; do
        IFS='§' read -r id time title data_source <<<"$item"
        echo -e "${GREEN}📦 NEW: $title${NC}"
        echo -e "${GREEN}    ID: $id | Link: https://steamcommunity.com/sharedfiles/filedetails/?id=$id${NC}"
    done

    for item in "${removed_items[@]}"; do
        IFS='§' read -r id time title data_source <<<"$item"
        echo -e "${RED}❌ REMOVED: $title${NC}"
        echo -e "${RED}    ID: $id | Link: https://steamcommunity.com/sharedfiles/filedetails/?id=$id${NC}"
    done

    for item in "${listed_items[@]}"; do
        IFS='§' read -r id time title old_source new_source <<<"$item"
        echo -e "${GREEN}✅ LISTED: $title - became publicly available${NC}"
        echo -e "${GREEN}    ID: $id | Link: https://steamcommunity.com/sharedfiles/filedetails/?id=$id${NC}"
        echo -e "${GREEN}    Source change: $old_source → $new_source${NC}"
    done

    for item in "${unlisted_items[@]}"; do
        IFS='§' read -r id time title old_source new_source <<<"$item"
        echo -e "${YELLOW}🔒 UNLISTED: $title - became private/unlisted${NC}"
        echo -e "${YELLOW}    ID: $id | Link: https://steamcommunity.com/sharedfiles/filedetails/?id=$id${NC}"
        echo -e "${YELLOW}    Source change: $old_source → $new_source${NC}"
    done

    for item in "${unavailable_items[@]}"; do
        IFS='§' read -r id time title _ _ <<<"$item"
        echo -e "${RED}💀 UNAVAILABLE: $title - no longer accessible${NC}"
        echo -e "${RED}    ID: $id | Link: https://steamcommunity.com/sharedfiles/filedetails/?id=$id${NC}"
    done

    for item in "${title_and_update_items[@]}"; do
        IFS='§' read -r id old_time new_time old_title new_title data_source <<<"$item"
        local old_time_utc old_time_local old_time_str
        local new_time_utc new_time_local new_time_str

        old_time_utc=$(date -d "@$old_time" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "Unknown")
        old_time_local=$(date -d "@$old_time" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
        if [ -n "$old_time_local" ] && [ "$old_time_local" != "Invalid" ]; then
            old_time_str="$old_time_utc ($old_time_local)"
        else
            old_time_str="$old_time_utc"
        fi

        new_time_utc=$(date -d "@$new_time" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "Unknown")
        new_time_local=$(date -d "@$new_time" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
        if [ -n "$new_time_local" ] && [ "$new_time_local" != "Invalid" ]; then
            new_time_str="$new_time_utc ($new_time_local)"
        else
            new_time_str="$new_time_utc"
        fi

        echo -e "${YELLOW}🔄📝 TITLE & UPDATE: \"$old_title\" → \"$new_title\"${NC}"
        echo -e "${YELLOW}    ID: $id | Link: https://steamcommunity.com/sharedfiles/filedetails/?id=$id${NC}"
        echo -e "${YELLOW}    Update: $old_time_str → $new_time_str${NC}"
    done

    for item in "${updated_items[@]}"; do
        IFS='§' read -r id old_time new_time title data_source <<<"$item"
        local old_time_utc old_time_local old_time_str
        local new_time_utc new_time_local new_time_str

        old_time_utc=$(date -d "@$old_time" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "Unknown")
        old_time_local=$(date -d "@$old_time" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
        if [ -n "$old_time_local" ] && [ "$old_time_local" != "Invalid" ]; then
            old_time_str="$old_time_utc ($old_time_local)"
        else
            old_time_str="$old_time_utc"
        fi

        new_time_utc=$(date -d "@$new_time" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "Unknown")
        new_time_local=$(date -d "@$new_time" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
        if [ -n "$new_time_local" ] && [ "$new_time_local" != "Invalid" ]; then
            new_time_str="$new_time_utc ($new_time_local)"
        else
            new_time_str="$new_time_utc"
        fi

        echo -e "${YELLOW}🔄 UPDATED: $title${NC}"
        echo -e "${YELLOW}    ID: $id | Link: https://steamcommunity.com/sharedfiles/filedetails/?id=$id${NC}"
        echo -e "${YELLOW}    $old_time_str → $new_time_str${NC}"
    done

    for item in "${title_changed_items[@]}"; do
        IFS='§' read -r id old_title new_title data_source <<<"$item"
        echo -e "${YELLOW}📝 TITLE CHANGED: \"$old_title\" → \"$new_title\"${NC}"
        echo -e "${YELLOW}    ID: $id | Link: https://steamcommunity.com/sharedfiles/filedetails/?id=$id${NC}"
    done

    echo ""
    echo -e "${GREEN}Summary:${NC}"
    echo -e "${GREEN}  New items: ${#new_items[@]}${NC}"
    echo -e "${GREEN}  Updated items: ${#updated_items[@]}${NC}"
    echo -e "${GREEN}  Removed items: ${#removed_items[@]}${NC}"
    echo -e "${GREEN}  Listed items: ${#listed_items[@]}${NC}"
    echo -e "${GREEN}  Unlisted items: ${#unlisted_items[@]}${NC}"
    echo -e "${GREEN}  Unavailable items: ${#unavailable_items[@]}${NC}"
    echo -e "${GREEN}  Title changed: ${#title_changed_items[@]}${NC}"
    echo -e "${GREEN}  Title + Update: ${#title_and_update_items[@]}${NC}"

    # Send Discord notifications if webhook is configured
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        echo -e "${YELLOW}Sending Discord notifications...${NC}"

        local all_embeds=()

        # Add new items (green)
        for item in "${new_items[@]}"; do
            IFS='§' read -r id time title data_source <<<"$item"
            local preview_url
            preview_url=$(jq -r --arg id "$id" '.items[] | select(.publishedfileid == $id) | .preview_url // empty' "$new_file" 2>/dev/null)
            all_embeds+=("$(create_item_embed "$id" "$title" "new" "" "$time" "5763719" "" "$preview_url")")
            echo -e "${YELLOW}  📦 Queued Discord notification: NEW - $title (ID: $id)${NC}"
        done

        # Add removed items (red)
        for item in "${removed_items[@]}"; do
            IFS='§' read -r id time title data_source <<<"$item"
            local preview_url
            preview_url=$(jq -r --arg id "$id" '.items[] | select(.publishedfileid == $id) | .preview_url // empty' "$old_file" 2>/dev/null)
            all_embeds+=("$(create_item_embed "$id" "$title" "removed" "$time" "" "15158332" "" "$preview_url")")
            echo -e "${YELLOW}  ❌ Queued Discord notification: REMOVED - $title (ID: $id)${NC}"
        done

        # Add listed items (blue)
        for item in "${listed_items[@]}"; do
            IFS='§' read -r id time title _ _ <<<"$item"
            local preview_url
            preview_url=$(jq -r --arg id "$id" '.items[] | select(.publishedfileid == $id) | .preview_url // empty' "$new_file" 2>/dev/null)
            all_embeds+=("$(create_item_embed "$id" "$title" "listed" "" "$time" "3447003" "" "$preview_url")")
            echo -e "${YELLOW}  ✅ Queued Discord notification: LISTED - $title (ID: $id)${NC}"
        done

        # Add unlisted items (orange)
        for item in "${unlisted_items[@]}"; do
            IFS='§' read -r id time title _ _ <<<"$item"
            local preview_url
            preview_url=$(jq -r --arg id "$id" '.items[] | select(.publishedfileid == $id) | .preview_url // empty' "$new_file" 2>/dev/null)
            all_embeds+=("$(create_item_embed "$id" "$title" "unlisted" "" "$time" "15105570" "" "$preview_url")")
            echo -e "${YELLOW}  🔒 Queued Discord notification: UNLISTED - $title (ID: $id)${NC}"
        done

        # Add unavailable items (dark red)
        for item in "${unavailable_items[@]}"; do
            IFS='§' read -r id time title _ _ <<<"$item"
            # For unavailable items, try to get preview from old file since current might not have it
            local preview_url
            preview_url=$(jq -r --arg id "$id" '.items[] | select(.publishedfileid == $id) | .preview_url // empty' "$old_file" 2>/dev/null)
            all_embeds+=("$(create_item_embed "$id" "$title" "unavailable" "" "$time" "10038562" "" "$preview_url")")
            echo -e "${YELLOW}  💀 Queued Discord notification: UNAVAILABLE - $title (ID: $id)${NC}"
        done

        # Add title and update changes (purple)
        for item in "${title_and_update_items[@]}"; do
            IFS='§' read -r id old_time new_time old_title new_title data_source <<<"$item"
            local preview_url
            preview_url=$(jq -r --arg id "$id" '.items[] | select(.publishedfileid == $id) | .preview_url // empty' "$new_file" 2>/dev/null)
            all_embeds+=("$(create_item_embed "$id" "$new_title" "title_and_update" "$old_time" "$new_time" "10181046" "$old_title" "$preview_url")")
            echo -e "${YELLOW}  🔄📝 Queued Discord notification: TITLE & UPDATE - \"$old_title\" → \"$new_title\" (ID: $id)${NC}"
        done

        # Add update only changes (yellow)
        for item in "${updated_items[@]}"; do
            IFS='§' read -r id old_time new_time title data_source <<<"$item"
            local preview_url
            preview_url=$(jq -r --arg id "$id" '.items[] | select(.publishedfileid == $id) | .preview_url // empty' "$new_file" 2>/dev/null)
            all_embeds+=("$(create_item_embed "$id" "$title" "updated" "$old_time" "$new_time" "16776960" "" "$preview_url")")
            echo -e "${YELLOW}  🔄 Queued Discord notification: UPDATED - $title (ID: $id)${NC}"
        done

        # Add title only changes (light blue)
        for item in "${title_changed_items[@]}"; do
            IFS='§' read -r id old_title new_title data_source <<<"$item"
            local preview_url
            preview_url=$(jq -r --arg id "$id" '.items[] | select(.publishedfileid == $id) | .preview_url // empty' "$new_file" 2>/dev/null)
            all_embeds+=("$(create_item_embed "$id" "$new_title" "title_changed" "" "" "5814783" "$old_title" "$preview_url")")
            echo -e "${YELLOW}  📝 Queued Discord notification: TITLE CHANGED - \"$old_title\" → \"$new_title\" (ID: $id)${NC}"
        done

        echo ""

        # Send in batches of MAX_DISCORD_EMBEDS
        local batch_count=0
        local embeds_batch=()

        for embed in "${all_embeds[@]}"; do
            embeds_batch+=("$embed")
            if [ ${#embeds_batch[@]} -ge $MAX_DISCORD_EMBEDS ]; then
                batch_count=$((batch_count + 1))
                local embeds_json
                embeds_json=$(printf '%s\n' "${embeds_batch[@]}" | jq -s '.')
                echo -e "${YELLOW}Sending Discord batch $batch_count (${#embeds_batch[@]} embeds)...${NC}"
                send_discord_notification "$embeds_json" "$COLLECTION_NAME"

                embeds_batch=()
                sleep 1 # Rate limit protection
            fi
        done
        if [ ${#embeds_batch[@]} -gt 0 ]; then
            batch_count=$((batch_count + 1))
            local embeds_json
            embeds_json=$(printf '%s\n' "${embeds_batch[@]}" | jq -s '.')
            echo -e "${YELLOW}Sending Discord batch $batch_count (${#embeds_batch[@]} embeds)...${NC}"
            send_discord_notification "$embeds_json" "$COLLECTION_NAME"
        fi

        echo -e "${GREEN}Discord notifications sent ($batch_count batches)${NC}"
    else
        echo -e "${YELLOW}Discord webhook not configured - skipping notifications${NC}"
    fi

    return 0
}

# Function for web scraping unavailable items
scrape_workshop_item() {
    local item_id="$1"

    # Generate random cache-busting parameters
    local timestamp
    timestamp=$(date +%s)
    local random_id random_token random_version
    random_id=$(cat /dev/urandom | tr -dc '0-9' | fold -w 10 | head -n 1)
    random_token=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)
    random_version=$(cat /dev/urandom | tr -dc '0-9' | fold -w 3 | head -n 1)

    # Build URL with cache-busting parameters
    local item_url="https://steamcommunity.com/sharedfiles/filedetails/?id=$item_id&t=$timestamp&_r=$random_id&v=$random_version&token=$random_token&nocache=1"
    local cookie_jar="$TEMP_DIR/cookies_${item_id}.txt"

    # Generate random session ID and browser fingerprint
    local session_id
    session_id=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | fold -w 32 | head -n 1)
    local random_chrome_version=$((110 + RANDOM % 10)) # 110-120

    # Randomized User-Agent
    local random_ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${random_chrome_version}.0.0.0 Safari/537.36"

    # Add delay to prevent rate limiting
    sleep "$SCRAPING_DELAY"

    # First request with cookie jar, random session, and realistic headers
    curl -s -m "$CURL_TIMEOUT" --compressed \
        -H "User-Agent: $random_ua" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9,de;q=0.8" \
        -H "Accept-Encoding: gzip, deflate, br" \
        -H "Cache-Control: no-cache" \
        -H "Pragma: no-cache" \
        -H "Sec-Ch-Ua: \"Chromium\";v=\"${random_chrome_version}\", \"Google Chrome\";v=\"${random_chrome_version}\", \"Not=A?Brand\";v=\"99\"" \
        -H "Sec-Ch-Ua-Mobile: ?0" \
        -H "Sec-Ch-Ua-Platform: \"Windows\"" \
        -H "Sec-Fetch-Dest: document" \
        -H "Sec-Fetch-Mode: navigate" \
        -H "Sec-Fetch-Site: none" \
        -H "Upgrade-Insecure-Requests: 1" \
        -H "X-Forwarded-For: $(printf "%d.%d.%d.%d" $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))" \
        -H "Session-Id: $session_id" \
        -c "$cookie_jar" \
        "$item_url" >/dev/null

    # Second request with saved cookies and session continuity
    local page_content
    if ! page_content=$(curl -s -m "$CURL_TIMEOUT" --compressed \
        -H "User-Agent: $random_ua" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9,de;q=0.8" \
        -H "Accept-Encoding: gzip, deflate, br" \
        -H "Cache-Control: max-age=0" \
        -H "Referer: https://steamcommunity.com/" \
        -H "Sec-Ch-Ua: \"Chromium\";v=\"${random_chrome_version}\", \"Google Chrome\";v=\"${random_chrome_version}\", \"Not=A?Brand\";v=\"99\"" \
        -H "Sec-Ch-Ua-Mobile: ?0" \
        -H "Sec-Ch-Ua-Platform: \"Windows\"" \
        -H "Sec-Fetch-Dest: document" \
        -H "Sec-Fetch-Mode: navigate" \
        -H "Sec-Fetch-Site: same-origin" \
        -H "Upgrade-Insecure-Requests: 1" \
        -H "Session-Id: $session_id" \
        -b "$cookie_jar" \
        "$item_url"); then
        echo "{\"publishedfileid\":\"$item_id\",\"time_updated\":null,\"title\":\"Unavailable resource\",\"result\":9,\"data_source\":null}"
        return
    fi

    # Extract item title
    local scraped_title
    scraped_title=$(echo "$page_content" | grep -o '<div class="workshopItemTitle">[^<]*' | sed 's/<div class="workshopItemTitle">//' | head -1)
    if [ -z "$scraped_title" ]; then
        scraped_title=$(echo "$page_content" | grep -o '<title>[^<]*</title>' | sed 's/<title>\(.*\) :: Steam Workshop<\/title>/\1/' | head -1)
    fi

    # Check for Steam Community Error page
    if echo "$page_content" | grep -q '<title>Steam Community :: Error</title>'; then
        echo "{\"publishedfileid\":\"$item_id\",\"time_updated\":null,\"title\":\"Steam Community :: Error\",\"result\":9,\"data_source\":\"unavailable\"}"
        return
    fi

    # Extract preview image URL from meta tag
    local preview_url
    preview_url=$(echo "$page_content" | grep -o 'rel="image_src"[^>]*href="[^"]*"' | sed 's/.*href="//; s/".*//' | head -1)
    # Remove everything after question mark
    if [ -n "$preview_url" ]; then
        preview_url="${preview_url%%\?*}"
    fi

    # Extract update time
    local scraped_time
    scraped_time=$(echo "$page_content" | grep -o '<div class="detailsStatRight">[^<]*</div>' | sed -n '3p' | sed 's/<[^>]*>//g' | head -1)
    if [ -z "$scraped_time" ]; then
        scraped_time=$(echo "$page_content" | grep -o 'data-timestamp="[0-9]*"' | sed 's/data-timestamp="//; s/"//' | head -1)
    fi

    # Process time
    local final_time="null"
    if [ -n "$scraped_time" ]; then
        if [[ "$scraped_time" =~ ^[0-9]+$ ]]; then
            final_time="$scraped_time"
        elif [[ "$scraped_time" =~ ([0-9]+)\ ([A-Za-z]+)(,\ ([0-9]{4}))?\ @\ ([0-9]{1,2}):([0-9]{2})([ap]m) ]]; then
            local day="${BASH_REMATCH[1]}"
            local month="${BASH_REMATCH[2]}"
            local year="${BASH_REMATCH[4]:-$(date +%Y)}"
            local hour="${BASH_REMATCH[5]}"
            local minute="${BASH_REMATCH[6]}"
            local ampm="${BASH_REMATCH[7]}"

            local timezone
            timezone=$(get_timezone "$month" "$day")
            local parsed_epoch
            parsed_epoch=$(TZ=UTC date -d "$month $day, $year $hour:$minute$ampm $timezone" '+%s' 2>/dev/null)

            [ -n "$parsed_epoch" ] && [[ "$parsed_epoch" =~ ^[0-9]+$ ]] && final_time="$parsed_epoch"
        fi
    fi

    # Create JSON - if we got any page content, assume item exists but is just restricted
    if [ -n "$scraped_title" ]; then
        local title_escaped
        title_escaped=$(escape_json "$scraped_title")
        if [ -n "$preview_url" ]; then
            echo "{\"publishedfileid\":\"$item_id\",\"time_updated\":$final_time,\"title\":\"$title_escaped\",\"result\":9,\"data_source\":\"scraped\",\"preview_url\":\"$preview_url\"}"
        else
            echo "{\"publishedfileid\":\"$item_id\",\"time_updated\":$final_time,\"title\":\"$title_escaped\",\"result\":9,\"data_source\":\"scraped\"}"
        fi
    elif [ -n "$page_content" ] && [ "$(echo "$page_content" | wc -c)" -gt 1000 ]; then
        # If we got substantial page content but no title, item likely exists but is restricted
        echo "{\"publishedfileid\":\"$item_id\",\"time_updated\":null,\"title\":\"Listed Item (No Title)\",\"result\":9,\"data_source\":\"scraped\"}"
    else
        # No meaningful page content - item is truly unavailable
        echo "{\"publishedfileid\":\"$item_id\",\"time_updated\":null,\"title\":\"Steam Community :: Error\",\"result\":9,\"data_source\":\"unavailable\"}"
    fi
}

# Function for batch querying of items
process_batch() {
    local batch_items=("$@")
    local batch_size=${#batch_items[@]}
    local batch_id
    batch_id=$(date +%s%N)_$$
    local batch_file="$TEMP_DIR/batch_${batch_id}.json"

    # Create POST data for batch request
    local post_data="itemcount=$batch_size"
    for i in "${!batch_items[@]}"; do
        post_data="$post_data&publishedfileids[$i]=${batch_items[$i]}"
    done

    # Batch API request with timeout
    local batch_response
    if ! batch_response=$(curl -s -m "$CURL_TIMEOUT" -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "$post_data" \
        "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"); then
        return
    fi
    if [ -n "$batch_response" ]; then
        # Extract desired fields for all items in batch
        echo "$batch_response" | jq -c '.response.publishedfiledetails[]' >"$batch_file.tmp" 2>/dev/null

        # Process items: handle successful (result=1) and failed (result=9) separately
        true >"$batch_file"
        while IFS= read -r item_data; do
            local result
            result=$(echo "$item_data" | jq -r '.result' 2>/dev/null)
            local item_id
            item_id=$(echo "$item_data" | jq -r '.publishedfileid' 2>/dev/null)

            if [ "$result" = "1" ]; then
                # Use successful items directly
                echo "$item_data" | jq '{
                    publishedfileid: .publishedfileid,
                    time_updated: .time_updated,
                    title: .title,
                    result: .result,
                    data_source: "api",
                    preview_url: .preview_url
                }' >>"$batch_file"
            elif [ "$result" = "9" ] && [ -n "$item_id" ]; then
                # Scrape failed items
                echo -e "${YELLOW}Scraping Item $item_id (not available via API)${NC}" >&2
                scraped_data=$(scrape_workshop_item "$item_id")
                echo "$scraped_data" >>"$batch_file"
            fi
        done <"$batch_file.tmp"

        rm -f "$batch_file.tmp"

        # Convert file to array format
        if [ -s "$batch_file" ]; then
            jq -s '.' "$batch_file" >"$batch_file.array" && mv "$batch_file.array" "$batch_file"
            echo "$batch_file" >>"$TEMP_DIR/batch_list.txt"
        fi
    fi
}

# Load detailed information for each item
echo -e "${YELLOW}Loading detailed information in batches of $BATCH_SIZE items...${NC}"

# Create JSON array
echo "{" >"$OUTPUT_FILE"
echo "  \"collection_id\": \"$COLLECTION_ID\"," >>"$OUTPUT_FILE"
if [ -n "$COLLECTION_NAME" ] && [ "$COLLECTION_NAME" != "null" ]; then
    echo "  \"collection_name\": \"$COLLECTION_NAME\"," >>"$OUTPUT_FILE"
fi

{
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"item_count\": $ITEM_COUNT,"
    echo "  \"items\": ["
} >>"$OUTPUT_FILE"

# Process items in batches
BATCH_COUNT=0
PROCESSED_ITEMS=0

for ((i = 0; i < ${#ITEMS_ARRAY[@]}; i += BATCH_SIZE)); do
    BATCH_COUNT=$((BATCH_COUNT + 1))

    # Current batch
    CURRENT_BATCH=("${ITEMS_ARRAY[@]:$i:$BATCH_SIZE}")
    CURRENT_BATCH_SIZE=${#CURRENT_BATCH[@]}

    echo -e "${YELLOW}Processing batch $BATCH_COUNT (items $(($i + 1))-$(($i + CURRENT_BATCH_SIZE))/$ITEM_COUNT)${NC}"

    # Process batch in parallel if fewer than MAX_PARALLEL are running
    while [ "$(jobs -r | wc -l)" -ge $MAX_PARALLEL ]; do
        sleep 0.1
    done

    # Start batch in background
    process_batch "${CURRENT_BATCH[@]}" &

    PROCESSED_ITEMS=$((PROCESSED_ITEMS + CURRENT_BATCH_SIZE))
done

# Wait for all background jobs
wait

echo -e "${YELLOW}Collecting batch results...${NC}"

# Collect all batch results
FIRST_ITEM=true
SAVED_ITEMS=0
PUBLIC_ITEMS=0
SCRAPED_ITEMS=0
UNAVAILABLE_ITEMS=0

# Process batch files in correct order
if [ -f "$TEMP_DIR/batch_list.txt" ]; then
    while IFS= read -r batch_file; do
        if [ -f "$batch_file" ] && [ -s "$batch_file" ]; then
            # Process each item in batch individually
            ITEM_COUNT_IN_BATCH=$(jq '. | length' "$batch_file" 2>/dev/null)

            if [ "$ITEM_COUNT_IN_BATCH" -gt 0 ] 2>/dev/null; then
                for ((j = 0; j < ITEM_COUNT_IN_BATCH; j++)); do
                    ITEM_JSON=$(jq ".[$j]" "$batch_file" 2>/dev/null)

                    if [ -n "$ITEM_JSON" ] && [ "$ITEM_JSON" != "null" ]; then
                        # Count item types based on data_source
                        data_source=$(echo "$ITEM_JSON" | jq -r '.data_source' 2>/dev/null)
                        case "$data_source" in
                        "api")
                            PUBLIC_ITEMS=$((PUBLIC_ITEMS + 1))
                            ;;
                        "scraped")
                            SCRAPED_ITEMS=$((SCRAPED_ITEMS + 1))
                            ;;
                        "unavailable")
                            UNAVAILABLE_ITEMS=$((UNAVAILABLE_ITEMS + 1))
                            ;;
                        *)
                            UNAVAILABLE_ITEMS=$((UNAVAILABLE_ITEMS + 1))
                            ;;
                        esac

                        if [ "$FIRST_ITEM" = false ]; then
                            echo "," >>"$OUTPUT_FILE"
                        fi
                        echo -n "    $ITEM_JSON" >>"$OUTPUT_FILE"
                        FIRST_ITEM=false
                        SAVED_ITEMS=$((SAVED_ITEMS + 1))
                    fi
                done
            fi
        fi
    done <"$TEMP_DIR/batch_list.txt"
else
    # Fallback: process all batch_*.json files
    for batch_file in "$TEMP_DIR"/batch_*.json; do
        if [ -f "$batch_file" ] && [ -s "$batch_file" ]; then
            ITEM_COUNT_IN_BATCH=$(jq '. | length' "$batch_file" 2>/dev/null)

            if [ "$ITEM_COUNT_IN_BATCH" -gt 0 ] 2>/dev/null; then
                for ((j = 0; j < ITEM_COUNT_IN_BATCH; j++)); do
                    ITEM_JSON=$(jq ".[$j]" "$batch_file" 2>/dev/null)

                    if [ -n "$ITEM_JSON" ] && [ "$ITEM_JSON" != "null" ]; then
                        # Count item types based on data_source
                        data_source=$(echo "$ITEM_JSON" | jq -r '.data_source' 2>/dev/null)
                        case "$data_source" in
                        "api")
                            PUBLIC_ITEMS=$((PUBLIC_ITEMS + 1))
                            ;;
                        "scraped")
                            SCRAPED_ITEMS=$((SCRAPED_ITEMS + 1))
                            ;;
                        "unavailable")
                            UNAVAILABLE_ITEMS=$((UNAVAILABLE_ITEMS + 1))
                            ;;
                        *)
                            UNAVAILABLE_ITEMS=$((UNAVAILABLE_ITEMS + 1))
                            ;;
                        esac

                        if [ "$FIRST_ITEM" = false ]; then
                            echo "," >>"$OUTPUT_FILE"
                        fi
                        echo -n "    $ITEM_JSON" >>"$OUTPUT_FILE"
                        FIRST_ITEM=false
                        SAVED_ITEMS=$((SAVED_ITEMS + 1))
                    fi
                done
            fi
        fi
    done
fi

# Close JSON array
echo "  ]" >>"$OUTPUT_FILE"
echo "}" >>"$OUTPUT_FILE"

# Format JSON with jq
echo -e "${YELLOW}Formatting JSON...${NC}"
jq '.' "$OUTPUT_FILE" >"${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"

echo -e "${GREEN}Done! Collection saved to '$OUTPUT_FILE'${NC}"
echo -e "${GREEN}Processed $ITEM_COUNT items total, saved $SAVED_ITEMS entries${NC}"
echo ""
echo -e "${GREEN}Item Statistics:${NC}"
echo -e "${GREEN}  Public items (API):     $PUBLIC_ITEMS${NC}"
echo -e "${GREEN}  Listed items (scraped): $SCRAPED_ITEMS${NC}"
echo -e "${GREEN}  Unavailable items:      $UNAVAILABLE_ITEMS${NC}"

# Display file size
if command -v du &>/dev/null; then
    FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    echo -e "${GREEN}File size: $FILE_SIZE${NC}"
fi

# Detect and report changes (only if old file exists)
if [ -f "$OLD_OUTPUT_FILE" ]; then
    detect_changes "$OUTPUT_FILE" "$OLD_OUTPUT_FILE"
fi
