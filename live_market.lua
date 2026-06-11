-- live_market.lua — Cloud Marketplace public display
-- Place on a computer with a monitor attached and a wireless modem.
-- Browse-only: no purchases, no login required.

local PROTOCOL      = "cloud_v1"
local REFRESH_SECS  = 30
local MON_SCALE     = 1

local mon = peripheral.find("monitor")
if not mon then error("No monitor attached") end
mon.setTextScale(MON_SCALE)
local W, H = mon.getSize()

for _, name in ipairs(peripheral.getNames()) do
    pcall(rednet.open, name)
end

-- ── RPC ──────────────────────────────────────────────────────────────────────
local serverId, rpcSeq = nil, 0
local function rpc(msg, timeout)
    rpcSeq = rpcSeq + 1
    msg._seq = rpcSeq
    local mySeq = rpcSeq
    if serverId then rednet.send(serverId, msg, PROTOCOL)
    else rednet.broadcast(msg, PROTOCOL) end
    local deadline = os.clock() + (timeout or 10)
    while true do
        local rem = deadline - os.clock()
        if rem <= 0 then return nil end
        local id, res = rednet.receive(PROTOCOL, rem)
        if not res then return nil end
        if id then serverId = id end
        if type(res) == "table" and res._seq == mySeq then return res end
    end
end

-- ── Bundling ──────────────────────────────────────────────────────────────────
local listings, bundles, serverNow = {}, {}, 0

local function ppi(l) return l.price / math.max(1, l.lot_size) end

local function buildBundles()
    local byName = {}
    for _, l in ipairs(listings) do
        local n = l.item_name
        if not byName[n] then byName[n] = {item_name=n, display_name=l.display_name, sellers={}, total_stock=0} end
        table.insert(byName[n].sellers, l)
        if (l.stock or 0) > 0 then byName[n].total_stock = byName[n].total_stock + l.stock end
    end
    local result = {}
    for _, b in pairs(byName) do
        table.sort(b.sellers, function(a, z)
            if (a.stock > 0) ~= (z.stock > 0) then return a.stock > 0 end
            return ppi(a) < ppi(z)
        end)
        b.best    = b.sellers[1]
        b.in_stock = b.total_stock > 0
        b.boosted = b.best and (b.best.boost_ts or 0) > serverNow
        table.insert(result, b)
    end
    table.sort(result, function(a, z)
        if a.boosted ~= z.boosted then return a.boosted end
        if a.in_stock ~= z.in_stock then return a.in_stock end
        return (a.best and ppi(a.best) or 0) < (z.best and ppi(z.best) or 0)
    end)
    bundles = result
end

local lastFetch = -REFRESH_SECS
local fetchOk   = false

local function fetchListings()
    local r
    for attempt = 1, 3 do
        r = rpc({type="market_public_list"}, 10)
        if r and r.ok then break end
        serverId = nil  -- forget cached server id, rebroadcast next attempt
        sleep(1)
    end
    if r and r.ok then
        listings   = r.listings or {}
        serverNow  = r.now or 0
        buildBundles()
        lastFetch  = os.clock()
        fetchOk    = true
    else
        fetchOk = false
    end
end

-- ── Drawing helpers ───────────────────────────────────────────────────────────
local function mset(fg, bg)
    if fg then mon.setTextColor(fg) end
    if bg then mon.setBackgroundColor(bg) end
end

local function mwrite(x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    mset(fg, bg)
    mon.write(text)
end

local function mfill(y, bg, fg, text)
    mon.setCursorPos(1, y)
    mon.setBackgroundColor(bg or colors.black)
    mon.clearLine()
    if text then
        mset(fg)
        mon.setCursorPos(math.floor((W - #text) / 2) + 1, y)
        mon.write(text)
    end
end

local function trunc(s, max)
    if #s > max then return s:sub(1, max - 1) .. "~" end
    return s
end

local function itemLabel(b)
    local s = (b.display_name or b.item_name):gsub("_", " ")
    return s
end

-- ── Layout constants (recalculated each draw since scale could change) ────────
-- Browse columns: Name | Sellers | Stock | Best Price
-- Sellers columns: Seller | Lot | Price | /item

local COL_SEL  = W - 9   -- "Sellers" col
local COL_STK  = W - 2   -- "Stock" (right-aligned, 8 chars from right)
-- actually let's compute properly:
-- right edge layout (right to left): price(9) | stock(6) | sellers(8) | name(rest)
local C_PRICE   = W - 8   -- price starts here (9 chars: "999sp/64 ")
local C_STOCK   = W - 14  -- stock (6 chars)
local C_SELLERS = W - 20  -- sellers count (6 chars)
local C_NAME    = 2       -- name starts here

-- ── Browse view ───────────────────────────────────────────────────────────────
local browseScroll = 0
local LIST_TOP     = 3
local LIST_BOT     = H - 1

local function drawBrowseHeader()
    mfill(1, colors.blue, colors.white, "  CLOUD MARKETPLACE  ")
    mfill(2, colors.gray)
    mset(colors.white, colors.gray)
    mon.setCursorPos(C_NAME, 2)    mon.write(trunc("Item", C_SELLERS - C_NAME - 1))
    mon.setCursorPos(C_SELLERS, 2) mon.write("Sell")
    mon.setCursorPos(C_STOCK, 2)   mon.write("Stock")
    mon.setCursorPos(C_PRICE, 2)   mon.write("Best Price")
end

local function drawBrowseRow(y, b, alt)
    mfill(y, alt and colors.gray or colors.black)
    if not b then return end
    local oos     = not b.in_stock
    local nameCol = b.boosted and colors.yellow or (oos and colors.gray or colors.white)
    local dataCol = oos and colors.gray or colors.lightGray

    local label = trunc(itemLabel(b), C_SELLERS - C_NAME - 1)
    mwrite(C_NAME, y, label, nameCol)
    mwrite(C_SELLERS, y, string.format("%-4d", #b.sellers), dataCol)
    if oos then
        mwrite(C_STOCK, y, "OOS  ", colors.red)
    else
        mwrite(C_STOCK, y, trunc(tostring(b.total_stock), 5), dataCol)
    end
    if b.best then
        local tag = b.best.price .. "sp/" .. b.best.lot_size
        mwrite(C_PRICE, y, trunc(tag, W - C_PRICE + 1), dataCol)
    end
end

local function drawBrowse()
    LIST_BOT = H - 1
    local listH = LIST_BOT - LIST_TOP + 1
    drawBrowseHeader()
    for i = 1, listH do
        drawBrowseRow(LIST_TOP + i - 1, bundles[i + browseScroll], i % 2 == 0)
    end
    -- Footer
    mfill(H, colors.gray)
    mset(colors.white, colors.gray)
    local age   = math.ceil(REFRESH_SECS - (os.clock() - lastFetch))
    local left  = "Touch an item to see sellers"
    local right = fetchOk and ("Refresh in " .. math.max(0, age) .. "s") or "Connecting..."
    local pad   = W - #left - #right - 2
    mon.setCursorPos(2, H)
    mon.write(left .. string.rep(" ", math.max(1, pad)) .. right)
end

-- ── Sellers view ──────────────────────────────────────────────────────────────
local sellersScroll  = 0
local selectedBundle = nil
local SEL_TOP        = 3

-- sellers columns
local SC_SELLER = 2
local SC_LOT    = W - 18
local SC_PRICE  = W - 11
local SC_PPI    = W - 5

local function drawSellersHeader(b)
    local title = trunc(itemLabel(b):upper(), W - 2)
    mfill(1, colors.blue, colors.white, title)
    mfill(2, colors.gray)
    mset(colors.white, colors.gray)
    mon.setCursorPos(SC_SELLER, 2) mon.write(trunc("Seller", SC_LOT - SC_SELLER - 1))
    mon.setCursorPos(SC_LOT,    2) mon.write("Lot")
    mon.setCursorPos(SC_PRICE,  2) mon.write("Price")
    mon.setCursorPos(SC_PPI,    2) mon.write("/item")
end

local function drawSellersRow(y, s, alt)
    mfill(y, alt and colors.gray or colors.black)
    if not s then return end
    local oos = (s.stock or 0) == 0
    local col = oos and colors.gray or colors.white
    mwrite(SC_SELLER, y, trunc(s.seller or "?", SC_LOT - SC_SELLER - 1), col)
    mwrite(SC_LOT,    y, trunc(tostring(s.lot_size), 4),                  col)
    mwrite(SC_PRICE,  y, trunc(s.price .. "sp", 6),                       col)
    mwrite(SC_PPI,    y, string.format("%.2f", ppi(s)),                   oos and colors.gray or colors.lightBlue)
    if oos then mwrite(W - 2, y, "OOS", colors.red) end
end

local BACK_Y  -- set in drawSellers

local function drawSellers()
    local b     = selectedBundle
    local listH = H - SEL_TOP - 2
    BACK_Y      = H - 1
    drawSellersHeader(b)
    for i = 1, listH do
        drawSellersRow(SEL_TOP + i - 1, b.sellers[i + sellersScroll], i % 2 == 0)
    end
    -- Back bar
    mfill(BACK_Y, colors.gray, colors.white)
    mon.setCursorPos(2, BACK_Y)
    mon.write("[ < Back ]")
    -- No-purchase notice
    mfill(H, colors.red, colors.white)
    mon.setCursorPos(2, H)
    mon.write("Visit Cloud Solutions on your tablet to purchase")
end

-- ── State machine ─────────────────────────────────────────────────────────────
local view = "browse"  -- "browse" | "sellers"

local function redraw()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    if view == "browse" then drawBrowse()
    else drawSellers() end
end

local function handleTouch(x, y)
    if view == "browse" then
        if y >= LIST_TOP and y <= LIST_BOT then
            local idx = (y - LIST_TOP + 1) + browseScroll
            if bundles[idx] then
                selectedBundle = bundles[idx]
                sellersScroll  = 0
                view = "sellers"
                redraw()
            end
        end
    else
        if y == BACK_Y then
            view = "browse"
            redraw()
        end
    end
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
fetchListings()
redraw()

local refreshTimer   = os.startTimer(REFRESH_SECS)
local countdownTimer = os.startTimer(1)

while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "monitor_touch" then
        handleTouch(p2, p3)
    elseif ev == "mouse_scroll" then
        if view == "browse" then
            local maxScroll = math.max(0, #bundles - (LIST_BOT - LIST_TOP + 1))
            browseScroll = math.max(0, math.min(browseScroll + p1, maxScroll))
            redraw()
        else
            local listH = H - SEL_TOP - 3
            local maxScroll = math.max(0, #selectedBundle.sellers - listH)
            sellersScroll = math.max(0, math.min(sellersScroll + p1, maxScroll))
            redraw()
        end
    elseif ev == "timer" then
        if p1 == refreshTimer then
            fetchListings()
            redraw()
            refreshTimer = os.startTimer(REFRESH_SECS)
        elseif p1 == countdownTimer then
            if view == "browse" then
                -- just update footer countdown without full redraw
                mfill(H, colors.gray)
                mset(colors.white, colors.gray)
                local age   = math.ceil(REFRESH_SECS - (os.clock() - lastFetch))
                local left  = "Touch an item to see sellers"
                local right = fetchOk and ("Refresh in " .. math.max(0, age) .. "s") or "Connecting..."
                local pad   = W - #left - #right - 2
                mon.setCursorPos(2, H)
                mon.write(left .. string.rep(" ", math.max(1, pad)) .. right)
            end
            countdownTimer = os.startTimer(1)
        end
    elseif ev == "key" and p1 == keys.q then
        mon.setBackgroundColor(colors.black) mon.clear()
        break
    end
end
