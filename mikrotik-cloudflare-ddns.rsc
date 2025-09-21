:local apiToken "<CLOUDFLARE_API_TOKEN>"
:local zoneID "<ZONE_ID>"
:local recordID "<DNS_RECORD_ID>"
:local domainName "<YOUR_DOMAIN>"

# Fetch current IP
:local currentIP ([/tool fetch url="https://api.ipify.org" mode=https output=user as-value]->"data")
:log info "Current IP: $currentIP"

# Resolve Cloudflare DNS IP
:local cloudflareDNSIP [:resolve $domainName server=1.1.1.1]
:log info "Cloudflare DNS IP: $cloudflareDNSIP"

# Check if update is needed
:if ($currentIP != $cloudflareDNSIP) do={
    :log info "Updating Cloudflare record. Old IP: $cloudflareDNSIP New IP: $currentIP"

    # Prepare HTTP headers and payload
    :local httpHeaders ("Authorization: Bearer " . $apiToken . "\r\nContent-Type: application/json")
    :local payload ("{\"type\":\"A\",\"name\":\"" . $domainName . "\",\"content\":\"" . $currentIP . "\",\"ttl\":120,\"proxied\":true}")
    :log info "HTTP Headers: $httpHeaders"
    :log info "Payload: $payload"

    # Send API request
    /tool fetch mode=https url="https://api.cloudflare.com/client/v4/zones/$zoneID/dns_records/$recordID" \
        http-method=put http-header=$httpHeaders http-data=$payload \
        output=user as-value
} else={
    :log info "No update needed. Current IP matches Cloudflare DNS."
}
