# === Constants from GitHub Secrets ===
$shopifyDomain = $env:SHOPIFY_DOMAIN
$accessToken   = $env:SHOPIFY_ACCESS_TOKEN
$dtdcToken     = $env:DTDC_TOKEN
$dtdcUrl       = $env:DTDC_URL
$bikWebhookUrl = $env:BIK_WEBHOOK_URL
$logFile       = "$PSScriptRoot\dtdc_to_bik_log.txt"

# === Start Logging ===
$date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path $logFile -Value "============================="
Add-Content -Path $logFile -Value "Script started at $date"

# === Shopify API Request ===
$sinceFulfillmentDate = (Get-Date).AddDays(-7).ToString("yyyy-MM-ddTHH:mm:sszzz")
$shopifyUrl = "https://$shopifyDomain/admin/api/2024-01/orders.json?status=any&fulfillment_status=shipped&fulfillment_created_at_min=$sinceFulfillmentDate&fields=id,email,phone,shipping_address,fulfillments,line_items,customer"

$headers = @{ "X-Shopify-Access-Token" = $accessToken }

try {
    $response = Invoke-RestMethod -Uri $shopifyUrl -Headers $headers -Method Get
    Add-Content -Path $logFile -Value "Fetched orders from Shopify."

    foreach ($order in $response.orders) {
        # === Customer Name ===
        $customerName = ""
        if ($order.shipping_address -and $order.shipping_address.name) {
            $customerName = $order.shipping_address.name
        } elseif ($order.customer) {
            $customerName = ($order.customer.first_name + " " + $order.customer.last_name).Trim()
        }

        # === Product Titles ===
        $productTitles = @()
        foreach ($item in $order.line_items) {
            $productTitles += $item.title
        }
        $productTitleString = $productTitles -join ", "

        $email = $order.email
        $phone = $order.phone
        if (-not $phone -and $order.shipping_address) {
            $phone = $order.shipping_address.phone
        }

        # === Phone Cleaning ===
        $phone = $phone -replace '[^\d]', ''
        if ($phone.Length -eq 10) {
            $phone = "+91$phone"
        } elseif ($phone.Length -gt 0 -and $phone.StartsWith("91")) {
            $phone = "+$phone"
        } elseif ($phone.Length -gt 0 -and -not $phone.StartsWith("+")) {
            $phone = "+$phone"
        }

        foreach ($fulfillment in $order.fulfillments) {
            foreach ($awb in $fulfillment.tracking_numbers) {
                if (-not $awb) { continue }

                $dtdcHeaders = @{ "x-access-token" = $dtdcToken }
                $dtdcBody = @{
                    trkType   = "cnno"
                    strcnno   = $awb
                    addtnlDtl = "Y"
                } | ConvertTo-Json -Compress

                try {
                    $dtdcResponse = Invoke-RestMethod -Uri $dtdcUrl -Method Post -Headers $dtdcHeaders -Body $dtdcBody -ContentType "application/json"
                    $trackDetails = $dtdcResponse.trackDetails

                    if ($trackDetails -and $trackDetails.Count -gt 0) {
                        $latestEvent = $trackDetails[-1]
                        $status = $latestEvent.strAction
                        $trackingUrl = "https://txk.dtdc.com/ctbs-tracking/customerInterface.tr?submitName=showCITrackingDetails&cType=Consignment&cnNo=$awb"

                        # === Build Payload in Exact Order ===
                        $payload = [ordered]@{
                            customer_name = $customerName
                            awb           = $awb
                            phone         = $phone
                            product_title = $productTitleString
                            email         = $email
                            status        = $status
                            tracking_url  = $trackingUrl
                        } | ConvertTo-Json -Compress

                        Add-Content -Path $logFile -Value "Sending to BIK: $payload"
                        Invoke-RestMethod -Uri $bikWebhookUrl -Method Post -Body $payload -ContentType "application/json"
                        Add-Content -Path $logFile -Value "Status sent to BIK: $awb"
                    }
                } catch {
                    Add-Content -Path $logFile -Value ("DTDC API error for AWB ${awb}: $($_.Exception.Message)")
                }
            }
        }
    }
} catch {
    Add-Content -Path $logFile -Value "Shopify fetch error: $($_.Exception.Message)"
}

Add-Content -Path $logFile -Value "Script ended at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Content -Path $logFile -Value "============================="
