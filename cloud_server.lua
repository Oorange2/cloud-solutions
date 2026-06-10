-- Cloud Server v3
local PROTOCOL   = "cloud_ui"
local SAVE_FILE  = "cloud_accounts.dat"
local BANK_FILE  = "bank_data.dat"
local BANK_VAULT = "create:item_vault_30"
local SPUR_ID      = "numismatics:spur"
local DENOMS = {
    {name="numismatics:sun",      label="Sun",      value=4096},
    {name="numismatics:crown",    label="Crown",    value=512},
    {name="numismatics:cog",      label="Cog",      value=64},
    {name="numismatics:sprocket", label="Sprocket", value=16},
    {name="numismatics:bevel",    label="Bevel",    value=8},
    {name="numismatics:spur",     label="Spur",     value=1},
}
local MARKET_VAULT = "create:item_vault_37"
local MARKET_FILE  = "market_data.dat"

local modemSide = nil
for _, s in ipairs({"top","bottom","left","right","front","back"}) do
    if peripheral.getType(s) == "modem" then modemSide = s break end
end
if not modemSide then error("No modem found") end
rednet.open(modemSide)

local accounts = {}
local sessions  = {}

local function save()
    local f = fs.open(SAVE_FILE, "w") f.write(textutils.serialize(accounts)) f.close()
end

local function load()
    if fs.exists(SAVE_FILE) then
        local f = fs.open(SAVE_FILE, "r")
        accounts = textutils.unserialize(f.readAll()) or {}
        f.close()
    end
    if not accounts["admin"] then
        accounts["admin"] = { password="2007", isAdmin=true, vault=nil, invmanager=nil, vaultDir="back", log={} }
        save()
    end
end
load()

local function makeToken()
    math.randomseed(os.clock() * 100000)
    local s = ""
    for i = 1, 16 do s = s .. string.format("%x", math.random(0,15)) end
    return s
end

local function getSession(tok)
    local s = sessions[tok]
    if not s then return nil end
    if os.time() > s.exp then sessions[tok] = nil return nil end
    s.exp = os.time() + 3600
    return s
end

local function pcallMethod(name, ...)
    local methods = {...}
    for _, method in ipairs(methods) do
        if peripheral.isPresent(name) then
            local ok, result = pcall(function() return peripheral.call(name, method) end)
            if ok and type(result) == "table" then return result, method end
        end
    end
    return nil, nil
end

local function listVault(uname)
    local acc = accounts[uname]
    if not acc or not acc.vault then return {}, "No vault configured" end
    if not peripheral.isPresent(acc.vault) then
        return {}, "Vault '" .. acc.vault .. "' not found"
    end
    local ok, items = pcall(function() return peripheral.call(acc.vault, "list") end)
    if not ok or type(items) ~= "table" then return {}, "vault.list() failed" end
    local merged = {}
    for slot, item in pairs(items) do
        if item and item.name then
            if not merged[item.name] then
                local d
                pcall(function() d = peripheral.call(acc.vault, "getItemDetail", slot) end)
                merged[item.name] = { name=item.name, displayName=(d and d.displayName) or item.name, count=0 }
            end
            merged[item.name].count = merged[item.name].count + item.count
        end
    end
    local list = {}
    for _, v in pairs(merged) do table.insert(list, v) end
    table.sort(list, function(a,b) return a.displayName < b.displayName end)
    return list, nil
end

local function listInv(uname)
    local acc = accounts[uname]
    if not acc or not acc.invmanager then return {}, "No inv manager configured" end
    if not peripheral.isPresent(acc.invmanager) then
        return {}, "InvMgr '" .. acc.invmanager .. "' not found"
    end
    local items = pcallMethod(acc.invmanager, "getItems", "getInventory", "list")
    if not items then return {}, "Could not list player inventory" end
    local merged = {}
    local function merge(tbl)
        if type(tbl) ~= "table" then return end
        for _, item in pairs(tbl) do
            if item and item.name then
                if not merged[item.name] then
                    merged[item.name] = { name=item.name, displayName=item.displayName or item.name, count=0 }
                end
                merged[item.name].count = merged[item.name].count + (item.count or 1)
            end
        end
    end
    merge(items)
    local ok2, armor = pcall(function() return peripheral.call(acc.invmanager, "getArmour") end)
    if not ok2 then ok2, armor = pcall(function() return peripheral.call(acc.invmanager, "getArmor") end) end
    if ok2 then merge(armor) end
    local list = {}
    for _, v in pairs(merged) do table.insert(list, v) end
    table.sort(list, function(a,b) return a.displayName < b.displayName end)
    return list, nil
end

local function addLog(uname, entry)
    local acc = accounts[uname]
    if not acc then return end
    acc.log = acc.log or {}
    table.insert(acc.log, { time=os.date("%H:%M %d/%m"), event=entry })
    while #acc.log > 200 do table.remove(acc.log, 1) end
    save()
end

local function doWithdraw(uname, name, count)
    local acc = accounts[uname]
    if not acc or not acc.vault or not acc.invmanager then return false, "Account not configured" end
    if not peripheral.isPresent(acc.vault)      then return false, "Vault not found: "   .. (acc.vault or "?") end
    if not peripheral.isPresent(acc.invmanager) then return false, "InvMgr not found: " .. (acc.invmanager or "?") end
    local ok, items = pcall(function() return peripheral.call(acc.vault, "list") end)
    local avail = 0
    if ok and type(items) == "table" then
        for _, item in pairs(items) do
            if item.name == name then avail = avail + item.count end
        end
    end
    if avail == 0 then return false, "Item not in vault" end
    count = math.min(count, avail)
    local moved
    local pok, err = pcall(function()
        moved = peripheral.call(acc.invmanager, "addItemToPlayer", acc.vaultDir or "back", { name=name, count=count })
    end)
    if not pok then return false, "addItemToPlayer error: " .. tostring(err) end
    if not moved or moved == 0 then return false, "Transfer returned 0" end
    return true, moved
end

local function doDeposit(uname, name, count)
    local acc = accounts[uname]
    if not acc or not acc.vault or not acc.invmanager then return false, "Account not configured" end
    if not peripheral.isPresent(acc.invmanager) then return false, "InvMgr not found: " .. (acc.invmanager or "?") end
    local moved
    local ok, err = pcall(function()
        moved = peripheral.call(acc.invmanager, "removeItemFromPlayer", acc.vaultDir or "back", { name=name, count=count })
    end)
    if not ok then return false, "removeItemFromPlayer error: " .. tostring(err) end
    if not moved or moved == 0 then return false, "Transfer returned 0" end
    return true, moved
end

-- ── Banking ──────────────────────────────────────────────────────────────────
local bankData = {}

local function saveBank()
    local f = fs.open(BANK_FILE, "w") f.write(textutils.serialize(bankData)) f.close()
end

local function loadBank()
    if fs.exists(BANK_FILE) then
        local f = fs.open(BANK_FILE, "r")
        bankData = textutils.unserialize(f.readAll()) or {}
        f.close()
    end
    if not bankData.accounts then bankData.accounts = {} end
end
loadBank()

local function getBankAcc(uname)
    if not bankData.accounts[uname] then
        bankData.accounts[uname] = { balance=0, dep_ts=os.epoch("utc"), loan=nil, credit=500, blog={} }
    end
    local b = bankData.accounts[uname]
    if b.credit       == nil then b.credit   = 500            end
    if b.dep_ts       == nil then b.dep_ts   = os.epoch("utc") end
    if b.blog         == nil then b.blog         = {}          end
    if b.notifications== nil then b.notifications= {}          end
    return b
end

local function addBankLog(uname, event)
    local b = getBankAcc(uname)
    table.insert(b.blog, { event=event, ts=os.epoch("utc") })
    while #b.blog > 100 do table.remove(b.blog, 1) end
end

local function addNotif(uname, msg)
    local b = getBankAcc(uname)
    if not b.notifications then b.notifications = {} end
    table.insert(b.notifications, { msg=msg, ts=os.epoch("utc"), read=false })
    while #b.notifications > 50 do table.remove(b.notifications, 1) end
end

local function getLoanRate(credit)
    if credit >= 750 then return 6
    elseif credit >= 600 then return 8
    elseif credit >= 450 then return 10
    elseif credit >= 300 then return 13
    else return nil end
end

local function countSpurs(vaultName)
    if not peripheral.isPresent(vaultName) then return 0 end
    local ok, items = pcall(function() return peripheral.call(vaultName, "list") end)
    if not ok or type(items) ~= "table" then return 0 end
    local total = 0
    for _, item in pairs(items) do
        if item.name == SPUR_ID then total = total + item.count end
    end
    return total
end

local function countVaultValue(vaultName)
    if not peripheral.isPresent(vaultName) then return 0 end
    local ok, items = pcall(function() return peripheral.call(vaultName, "list") end)
    if not ok or type(items) ~= "table" then return 0 end
    local denomVal = {}
    for _, d in ipairs(DENOMS) do denomVal[d.name] = d.value end
    local total = 0
    for _, item in pairs(items) do
        total = total + item.count * (denomVal[item.name] or 0)
    end
    return total
end

local function moveSpurs(fromV, toV, amount)
    if not peripheral.isPresent(fromV) then return 0 end
    if not peripheral.isPresent(toV)   then return 0 end
    local ok, items = pcall(function() return peripheral.call(fromV, "list") end)
    if not ok or type(items) ~= "table" then return 0 end
    local moved = 0
    for slot, item in pairs(items) do
        if item.name == SPUR_ID and moved < amount then
            local ok2, n = pcall(function()
                return peripheral.call(fromV, "pushItems", toV, slot, amount - moved)
            end)
            if ok2 and n then moved = moved + n end
        end
    end
    return moved
end

local function moveItem(fromV, toV, itemName, count)
    if not peripheral.isPresent(fromV) then return 0 end
    if not peripheral.isPresent(toV)   then return 0 end
    local ok, items = pcall(function() return peripheral.call(fromV, "list") end)
    if not ok or type(items) ~= "table" then return 0 end
    local moved = 0
    for slot, item in pairs(items) do
        if item.name == itemName and moved < count then
            local ok2, n = pcall(function()
                return peripheral.call(fromV, "pushItems", toV, slot, count - moved)
            end)
            if ok2 and n then moved = moved + n end
        end
    end
    return moved
end

local function applyDepInterest(uname)
    local b = getBankAcc(uname)
    if b.balance <= 0 then return end
    local now  = os.epoch("utc")
    local days = math.floor((now - b.dep_ts) / 86400000)
    if days <= 0 then return end
    local gained = math.floor(b.balance * 0.02 * days)
    if gained > 0 then
        b.balance = b.balance + gained
        addBankLog(uname, "Interest +" .. gained .. " sp (" .. days .. "d)")
    end
    b.dep_ts = b.dep_ts + days * 86400000
end

local function applyLoanInterest(uname)
    local b = getBankAcc(uname)
    if not b.loan then return end
    local now  = os.epoch("utc")
    local days = math.floor((now - b.loan.int_ts) / 86400000)
    if days > 0 then
        local interest = math.ceil(b.loan.remaining * (b.loan.rate / 100) * days)
        b.loan.remaining = b.loan.remaining + interest
        b.loan.int_ts    = b.loan.int_ts + days * 86400000
        addBankLog(uname, "Loan interest +" .. interest .. " sp")
    end
    if now > b.loan.due_ts and not b.loan.penalized then
        b.loan.penalized = true
        b.credit = math.max(0, b.credit - 100)
        addBankLog(uname, "Loan overdue! Credit -100")
    end
end

local function totalDeposits()
    local t = 0
    for _, b in pairs(bankData.accounts) do t = t + (b.balance or 0) end
    return t
end

local function totalLoans()
    local t = 0
    for _, b in pairs(bankData.accounts) do
        if b.loan then t = t + (b.loan.remaining or 0) end
    end
    return t
end

local function calcMarketTax(price)
    if price < 5 then return 0
    elseif price <= 20 then return 1
    else return math.floor(price * 0.05) end
end

-- ── Marketplace data ─────────────────────────────────────────────────────────
local marketData = {}
local function saveMarket()
    local f = fs.open(MARKET_FILE,"w") f.write(textutils.serialize(marketData)) f.close()
end
local function loadMarket()
    if fs.exists(MARKET_FILE) then
        local f = fs.open(MARKET_FILE,"r")
        marketData = textutils.unserialize(f.readAll()) or {}
        f.close()
    end
    if not marketData.listings then marketData.listings = {} end
    if not marketData.next_id  then marketData.next_id  = 1  end
end
loadMarket()

local STALE_LISTING_MS = 3 * 86400000  -- 3 real days in milliseconds
local function pruneStaleListings()
    local now = os.epoch("utc")
    local pruned = 0
    for key, l in pairs(marketData.listings) do
        if l.out_of_stock_ts and (now - l.out_of_stock_ts) > STALE_LISTING_MS then
            marketData.listings[key] = nil
            pruned = pruned + 1
            print("Removed stale listing #"..tostring(l.id).." ("..tostring(l.item_name)..")")
        end
    end
    if pruned > 0 then saveMarket() end
end

-- ── Message handler ──────────────────────────────────────────────────────────
local function handle(cid, msg)
    if type(msg) ~= "table" then return end

    if msg.type == "login" then
        local acc = accounts[msg.username]
        if not acc or acc.password ~= msg.password then
            rednet.send(cid, { ok=false, err="Invalid credentials" }, PROTOCOL) return
        end
        local tok   = makeToken()
        local admin = acc.isAdmin or msg.username == "admin"
        sessions[tok] = { username=msg.username, isAdmin=admin, exp=os.time()+3600 }
        if not admin then addLog(msg.username, "Logged in") end
        local unread = 0
        if not admin then
            local b = getBankAcc(msg.username)
            for _, n in ipairs(b.notifications or {}) do
                if not n.read then unread = unread + 1 end
            end
        end
        rednet.send(cid, { ok=true, token=tok, isAdmin=admin, unread_notifs=unread }, PROTOCOL)
        print(msg.username .. " logged in")
        return
    end

    if msg.type == "debug_peripherals" then
        rednet.send(cid, { names=peripheral.getNames() }, PROTOCOL) return
    end

    local sess = getSession(msg.token)
    if not sess then rednet.send(cid, { err="Session expired" }, PROTOCOL) return end
    local uname = sess.username

    if msg.type == "list_vault" then
        local items, err = listVault(uname)
        rednet.send(cid, { items=items, err=err }, PROTOCOL)

    elseif msg.type == "list_inventory" then
        local items, err = listInv(uname)
        rednet.send(cid, { items=items, err=err }, PROTOCOL)

    elseif msg.type == "withdraw" then
        local ok, r = doWithdraw(uname, msg.name, msg.count or 1)
        if ok then addLog(uname, "Withdrew x"..r.." "..(msg.displayName or msg.name)) end
        rednet.send(cid, { ok=ok, err=not ok and r or nil }, PROTOCOL)

    elseif msg.type == "deposit" then
        local ok, r = doDeposit(uname, msg.name, msg.count or 1)
        if ok then addLog(uname, "Deposited x"..r.." "..(msg.displayName or msg.name)) end
        rednet.send(cid, { ok=ok, err=not ok and r or nil }, PROTOCOL)

    elseif msg.type == "get_log" then
        local acc = accounts[uname]
        rednet.send(cid, { log=(acc and acc.log) or {} }, PROTOCOL)

    elseif msg.type == "admin_list_users" then
        if not sess.isAdmin then rednet.send(cid, { err="Not authorized" }, PROTOCOL) return end
        local list = {}
        for u, acc in pairs(accounts) do
            if u ~= "admin" then table.insert(list, { username=u, vault=acc.vault, invmanager=acc.invmanager }) end
        end
        rednet.send(cid, { users=list }, PROTOCOL)

    elseif msg.type == "admin_create_user" then
        if not sess.isAdmin then rednet.send(cid, { err="Not authorized" }, PROTOCOL) return end
        if accounts[msg.username] then rednet.send(cid, { ok=false, err="User exists" }, PROTOCOL) return end
        accounts[msg.username] = {
            password=msg.password, vault=msg.vault,
            invmanager=msg.invmanager, vaultDir=msg.vaultDir or "back", log={}
        }
        save()
        rednet.send(cid, { ok=true }, PROTOCOL)
        print("Created user: "..msg.username)

    elseif msg.type == "admin_delete_user" then
        if not sess.isAdmin then rednet.send(cid, { err="Not authorized" }, PROTOCOL) return end
        accounts[msg.username] = nil save()
        rednet.send(cid, { ok=true }, PROTOCOL)

    elseif msg.type == "admin_view_vault" then
        if not sess.isAdmin then rednet.send(cid, { err="Not authorized" }, PROTOCOL) return end
        local items, err = listVault(msg.username)
        rednet.send(cid, { items=items, err=err }, PROTOCOL)

    elseif msg.type == "admin_view_inventory" then
        if not sess.isAdmin then rednet.send(cid, { err="Not authorized" }, PROTOCOL) return end
        local items, err = listInv(msg.username)
        rednet.send(cid, { items=items, err=err }, PROTOCOL)

    elseif msg.type == "admin_withdraw" then
        if not sess.isAdmin then rednet.send(cid, { err="Not authorized" }, PROTOCOL) return end
        local ok, r = doWithdraw(msg.username, msg.name, msg.count or 1)
        rednet.send(cid, { ok=ok, err=not ok and r or nil }, PROTOCOL)

    elseif msg.type == "admin_deposit" then
        if not sess.isAdmin then rednet.send(cid, { err="Not authorized" }, PROTOCOL) return end
        local ok, r = doDeposit(msg.username, msg.name, msg.count or 1)
        rednet.send(cid, { ok=ok, err=not ok and r or nil }, PROTOCOL)

    -- ── Bank handlers ─────────────────────────────────────────────────────────
    elseif msg.type == "bank_info" then
        applyDepInterest(uname) applyLoanInterest(uname) saveBank()
        local b    = getBankAcc(uname)
        local loan = nil
        if b.loan then
            local now = os.epoch("utc")
            loan = {
                original  = b.loan.amount,
                remaining = b.loan.remaining,
                rate      = b.loan.rate,
                daysLeft  = math.ceil((b.loan.due_ts - now) / 86400000),
                overdue   = now > b.loan.due_ts,
            }
        end
        local vaultVal = countVaultValue(BANK_VAULT)
        local ok_bd, blist = pcall(function() return peripheral.call(BANK_VAULT,"list") end)
        local bdCounts = {}
        if ok_bd and type(blist)=="table" then
            for _, item in pairs(blist) do
                bdCounts[item.name] = (bdCounts[item.name] or 0) + item.count
            end
        end
        local bankDenoms = {}
        for _, d in ipairs(DENOMS) do bankDenoms[d.name] = bdCounts[d.name] or 0 end
        rednet.send(cid, {
            ok         = true,
            balance    = b.balance,
            credit     = b.credit,
            loan       = loan,
            loanRate   = getLoanRate(b.credit),
            loanCap    = math.max(0, math.floor(vaultVal*0.4) - totalLoans()),
            bankSpurs  = vaultVal,
            bankDenoms = bankDenoms,
        }, PROTOCOL)

    elseif msg.type == "bank_deposit" then
        local acc    = accounts[uname]
        local b      = getBankAcc(uname)
        local coins  = msg.coins or {}
        local source = msg.source or "vault"
        if not acc.vault or not peripheral.isPresent(acc.vault) then
            rednet.send(cid,{ok=false,err="No vault configured"},PROTOCOL) return
        end
        -- If inventory, pull each coin type into player vault first
        if source == "inventory" then
            if not acc.invmanager or not peripheral.isPresent(acc.invmanager) then
                rednet.send(cid,{ok=false,err="No inventory manager"},PROTOCOL) return
            end
            for _, d in ipairs(DENOMS) do
                local cnt = math.max(0, math.floor(tonumber(coins[d.name]) or 0))
                if cnt > 0 then
                    local ok2, n = pcall(function()
                        return peripheral.call(acc.invmanager,"removeItemFromPlayer",
                            acc.vaultDir or "back",{name=d.name,count=cnt})
                    end)
                    coins[d.name] = (ok2 and n and n>0) and n or 0
                end
            end
        end
        -- Move from player vault to bank vault, tallying spur value
        local total_sp = 0
        for _, d in ipairs(DENOMS) do
            local cnt = math.max(0, math.floor(tonumber(coins[d.name]) or 0))
            if cnt > 0 then
                local actual = moveItem(acc.vault, BANK_VAULT, d.name, cnt)
                total_sp = total_sp + actual * d.value
            end
        end
        if total_sp == 0 then
            rednet.send(cid,{ok=false,err="No coins deposited"},PROTOCOL) return
        end
        applyDepInterest(uname)
        b.balance = b.balance + total_sp
        addBankLog(uname,"Deposited "..total_sp.." sp")
        saveBank()
        rednet.send(cid,{ok=true,moved=total_sp,balance=b.balance},PROTOCOL)
        print(uname.." bank deposit: "..total_sp.." sp")

    elseif msg.type == "bank_withdraw" then
        local acc   = accounts[uname]
        local b     = getBankAcc(uname)
        applyDepInterest(uname)
        local coins = msg.coins or {}
        -- Calculate total sp from requested coin breakdown
        local total_sp = 0
        for _, d in ipairs(DENOMS) do
            local cnt = math.max(0, math.floor(tonumber(coins[d.name]) or 0))
            total_sp = total_sp + cnt * d.value
        end
        if total_sp <= 0 then
            rednet.send(cid,{ok=false,err="No amount specified"},PROTOCOL) return
        end
        if total_sp > b.balance then
            rednet.send(cid,{ok=false,err="Only "..b.balance.." sp in account"},PROTOCOL) return
        end
        if not acc.vault or not peripheral.isPresent(acc.vault) then
            rednet.send(cid,{ok=false,err="No vault configured"},PROTOCOL) return
        end
        if not acc.invmanager or not peripheral.isPresent(acc.invmanager) then
            rednet.send(cid,{ok=false,err="No inventory manager"},PROTOCOL) return
        end
        -- Verify bank has each denomination requested
        local bankItems = {}
        for _, item in pairs(peripheral.call(BANK_VAULT,"list") or {}) do
            bankItems[item.name] = (bankItems[item.name] or 0) + item.count
        end
        for _, d in ipairs(DENOMS) do
            local cnt = math.max(0, math.floor(tonumber(coins[d.name]) or 0))
            if cnt > 0 and (bankItems[d.name] or 0) < cnt then
                rednet.send(cid,{ok=false,err="Bank lacks enough "..d.label.." coins"},PROTOCOL) return
            end
        end
        -- Step 1: move coins bank vault → player vault
        local moved = {}
        for _, d in ipairs(DENOMS) do
            local cnt = math.max(0, math.floor(tonumber(coins[d.name]) or 0))
            if cnt > 0 then moved[d.name] = moveItem(BANK_VAULT, acc.vault, d.name, cnt) end
        end
        -- Step 2: player vault → player inventory; reverse all on failure
        for _, d in ipairs(DENOMS) do
            local cnt = moved[d.name] or 0
            if cnt > 0 then
                local ok3, given = pcall(function()
                    return peripheral.call(acc.invmanager,"addItemToPlayer",
                        acc.vaultDir or "back",{name=d.name,count=cnt})
                end)
                if not ok3 or not given or given == 0 then
                    for _, d2 in ipairs(DENOMS) do
                        if (moved[d2.name] or 0) > 0 then
                            moveItem(acc.vault, BANK_VAULT, d2.name, moved[d2.name])
                        end
                    end
                    rednet.send(cid,{ok=false,err="Inventory full! Clear space first"},PROTOCOL) return
                end
            end
        end
        b.balance = b.balance - total_sp
        addBankLog(uname,"Withdrew "..total_sp.." sp")
        saveBank()
        rednet.send(cid,{ok=true,moved=total_sp,balance=b.balance},PROTOCOL)
        print(uname.." bank withdraw: "..total_sp.." sp")

    elseif msg.type == "bank_get_loan" then
        local acc    = accounts[uname]
        local b      = getBankAcc(uname)
        applyLoanInterest(uname)
        if b.loan then
            rednet.send(cid, {ok=false, err="Already have an active loan"}, PROTOCOL) return
        end
        local rate = getLoanRate(b.credit)
        if not rate then
            rednet.send(cid, {ok=false, err="Credit score too low (need 300+)"}, PROTOCOL) return
        end
        local amount = math.max(1, math.min(64, tonumber(msg.amount) or 0))
        local cap    = math.max(0, math.floor(countVaultValue(BANK_VAULT)*0.4) - totalLoans())
        if amount > cap then
            rednet.send(cid, {ok=false, err="Bank cannot finance this loan right now"}, PROTOCOL) return
        end
        local now = os.epoch("utc")
        b.balance = b.balance + amount
        b.loan = {
            amount    = amount,
            remaining = amount,
            rate      = rate,
            taken_ts  = now,
            due_ts    = now + 5 * 86400000,
            int_ts    = now,
            penalized = false,
        }
        addBankLog(uname, "Loan: " .. amount .. " sp @ " .. rate .. "%/day, due 5d")
        saveBank()
        rednet.send(cid, {ok=true, amount=amount, rate=rate}, PROTOCOL)
        print(uname .. " took loan: " .. amount .. " sp @ " .. rate .. "%/day")

    elseif msg.type == "bank_pay_loan" then
        local acc    = accounts[uname]
        local b      = getBankAcc(uname)
        applyLoanInterest(uname)
        if not b.loan then rednet.send(cid, {ok=false, err="No active loan"}, PROTOCOL) return end
        local amount = math.min(tonumber(msg.amount) or 0, b.loan.remaining)
        if amount <= 0 then rednet.send(cid, {ok=false, err="Invalid amount"}, PROTOCOL) return end
        if b.balance < amount then
            rednet.send(cid, {ok=false, err="Not enough balance (have "..b.balance.." sp)"}, PROTOCOL) return
        end
        b.balance = b.balance - amount
        local moved = amount
        b.loan.remaining = b.loan.remaining - moved
        local now2     = os.epoch("utc")
        local onTime   = now2 <= b.loan.due_ts
        local heldDay  = (now2 - b.loan.taken_ts) >= 86400000
        local fullPay  = b.loan.remaining <= 0
        if fullPay then
            if onTime and heldDay then
                b.credit = math.min(900, b.credit + 20)
                addBankLog(uname, "Loan cleared on time. Credit +20")
            elseif not onTime then
                b.credit = math.max(0, b.credit - 20)
                addBankLog(uname, "Loan cleared late. Credit -20")
            else
                addBankLog(uname, "Loan cleared (held <1d, no credit change)")
            end
            b.loan = nil
        else
            addBankLog(uname, "Paid " .. moved .. " sp. Left: " .. b.loan.remaining)
        end
        saveBank()
        rednet.send(cid, {
            ok=true, paid=moved,
            remaining = b.loan and b.loan.remaining or 0,
            loanCleared = fullPay,
            credit = b.credit
        }, PROTOCOL)

    elseif msg.type == "bank_get_log" then
        local b = getBankAcc(uname)
        local out = {}
        for i = #b.blog, 1, -1 do table.insert(out, b.blog[i]) end
        rednet.send(cid, {ok=true, log=out}, PROTOCOL)

    elseif msg.type == "get_notif_count" then
        local b = getBankAcc(uname)
        local count = 0
        for _, n in ipairs(b.notifications or {}) do
            if not n.read then count = count + 1 end
        end
        rednet.send(cid, {ok=true, count=count}, PROTOCOL)

    elseif msg.type == "get_notifications" then
        local b = getBankAcc(uname)
        local notifs = b.notifications or {}
        for _, n in ipairs(notifs) do n.read = true end
        saveBank()
        rednet.send(cid, {ok=true, notifications=notifs}, PROTOCOL)

    -- ── Market handlers ───────────────────────────────────────────────────────
    elseif msg.type == "market_create_listing" then
        local lot_size = math.max(1, math.floor(tonumber(msg.lot_size) or 1))
        local price    = math.max(0, math.floor(tonumber(msg.price)    or 0))
        if not msg.item_name then rednet.send(cid,{ok=false,err="No item specified"},PROTOCOL) return end
        -- Merge with identical existing listing
        for _, l in pairs(marketData.listings) do
            if l.seller==uname and l.item_name==msg.item_name
               and l.lot_size==lot_size and l.price==price then
                rednet.send(cid,{ok=true,id=l.id,merged=true,stock=l.stock},PROTOCOL) return
            end
        end
        local nid = marketData.next_id
        marketData.next_id = nid + 1
        local now_ts = os.epoch("utc")
        marketData.listings[tostring(nid)] = {
            id=nid, seller=uname,
            item_name=msg.item_name, display_name=msg.display_name or msg.item_name,
            lot_size=lot_size, price=price, stock=0,
            listed_ts=now_ts, out_of_stock_ts=now_ts,
        }
        saveMarket()
        rednet.send(cid,{ok=true,id=nid,merged=false,stock=0},PROTOCOL)
        print(uname.." created listing for "..msg.item_name)

    elseif msg.type == "market_list" then
        pruneStaleListings()
        local now = os.epoch("utc")
        local active = {}
        for _, l in pairs(marketData.listings) do
            table.insert(active, {
                id=l.id, seller=l.seller,
                item_name=l.item_name, display_name=l.display_name,
                lot_size=l.lot_size, price=l.price, stock=l.stock,
                listed_ts=l.listed_ts, boost_ts=l.boost_ts,
            })
        end
        table.sort(active, function(a,b)
            local aBoosted = (a.boost_ts or 0) > now
            local bBoosted = (b.boost_ts or 0) > now
            if aBoosted ~= bBoosted then return aBoosted end
            return (a.listed_ts or 0) > (b.listed_ts or 0)
        end)
        rednet.send(cid, {ok=true, listings=active}, PROTOCOL)

    elseif msg.type == "market_sell" then
        local acc    = accounts[uname]
        local lot_size = math.max(1, math.floor(tonumber(msg.lot_size) or 1))
        local price    = math.max(0, math.floor(tonumber(msg.price)    or 0))
        local lots     = math.max(1, math.floor(tonumber(msg.lots)     or 1))
        local total    = lot_size * lots
        local moved    = 0
        if msg.source == "inventory" then
            if not acc or not acc.invmanager or not peripheral.isPresent(acc.invmanager) then
                rednet.send(cid,{ok=false,err="No inventory manager"},PROTOCOL) return
            end
            local ok2,n = pcall(function()
                return peripheral.call(acc.invmanager,"removeItemFromPlayer",
                    acc.vaultDir or "back",{name=msg.item_name,count=total})
            end)
            if not ok2 or not n or n==0 then rednet.send(cid,{ok=false,err="Item not in inventory"},PROTOCOL) return end
            moved = moveItem(acc.vault, MARKET_VAULT, msg.item_name, n)
            if moved < lot_size then
                if moved>0 then moveItem(MARKET_VAULT,acc.vault,msg.item_name,moved) end
                rednet.send(cid,{ok=false,err="Market vault transfer failed"},PROTOCOL) return
            end
        else
            if not acc or not acc.vault or not peripheral.isPresent(acc.vault) then
                rednet.send(cid,{ok=false,err="No vault"},PROTOCOL) return
            end
            moved = moveItem(acc.vault, MARKET_VAULT, msg.item_name, total)
            if moved < lot_size then
                if moved>0 then moveItem(MARKET_VAULT,acc.vault,msg.item_name,moved) end
                rednet.send(cid,{ok=false,err="Not enough items in vault"},PROTOCOL) return
            end
        end
        local actual_lots = math.floor(moved / lot_size)
        local remainder   = moved - actual_lots * lot_size
        if remainder > 0 then moveItem(MARKET_VAULT, acc.vault, msg.item_name, remainder) end
        -- Merge with existing matching listing
        local merged_id = nil
        for key, l in pairs(marketData.listings) do
            if l.seller==uname and l.item_name==msg.item_name
               and l.lot_size==lot_size and l.price==price then
                l.stock = l.stock + actual_lots
                merged_id = l.id
                saveMarket()
                rednet.send(cid,{ok=true,id=l.id,lots=actual_lots,stock=l.stock,merged=true},PROTOCOL) return
            end
        end
        local nid = marketData.next_id
        marketData.next_id = nid + 1
        marketData.listings[tostring(nid)] = {
            id=nid, seller=uname,
            item_name=msg.item_name, display_name=msg.display_name or msg.item_name,
            lot_size=lot_size, price=price, stock=actual_lots,
            listed_ts=os.epoch("utc"),
        }
        saveMarket()
        rednet.send(cid,{ok=true,id=nid,lots=actual_lots,stock=actual_lots,merged=false},PROTOCOL)
        print(uname.." listed "..actual_lots.." lot(s) of "..msg.item_name)

    elseif msg.type == "market_add_stock" then
        local acc = accounts[uname]
        local l   = marketData.listings[tostring(msg.listing_id)]
        if not l then rednet.send(cid,{ok=false,err="Listing not found"},PROTOCOL) return end
        if l.seller ~= uname then rednet.send(cid,{ok=false,err="Not your listing"},PROTOCOL) return end
        local lots  = math.max(1, math.floor(tonumber(msg.lots) or 1))
        local total = lots * l.lot_size
        local moved = 0
        if msg.source == "inventory" then
            if not acc.invmanager or not peripheral.isPresent(acc.invmanager) then
                rednet.send(cid,{ok=false,err="No inventory manager"},PROTOCOL) return
            end
            local ok2,n = pcall(function()
                return peripheral.call(acc.invmanager,"removeItemFromPlayer",
                    acc.vaultDir or "back",{name=l.item_name,count=total})
            end)
            if not ok2 or not n or n==0 then rednet.send(cid,{ok=false,err="Item not in inventory"},PROTOCOL) return end
            moved = moveItem(acc.vault, MARKET_VAULT, l.item_name, n)
        else
            moved = moveItem(acc.vault, MARKET_VAULT, l.item_name, total)
        end
        local actual = math.floor(moved / l.lot_size)
        local rem    = moved - actual * l.lot_size
        if rem > 0 then moveItem(MARKET_VAULT, acc.vault, l.item_name, rem) end
        if actual == 0 then rednet.send(cid,{ok=false,err="No items transferred"},PROTOCOL) return end
        l.stock = l.stock + actual
        l.out_of_stock_ts = nil  -- restocked, reset expiry timer
        saveMarket()
        rednet.send(cid,{ok=true,added=actual,stock=l.stock},PROTOCOL)

    elseif msg.type == "market_buy" then
        local acc      = accounts[uname]
        local l        = marketData.listings[tostring(msg.listing_id)]
        if not l             then rednet.send(cid,{ok=false,err="Listing not found"},PROTOCOL) return end
        if l.stock <= 0      then rednet.send(cid,{ok=false,err="Out of stock"},PROTOCOL) return end
        if l.seller == uname then rednet.send(cid,{ok=false,err="Cannot buy your own listing"},PROTOCOL) return end
        local qty = math.max(1, math.min(math.floor(tonumber(msg.quantity) or 1), l.stock))
        applyDepInterest(uname) applyLoanInterest(uname)
        local b = getBankAcc(uname)
        local totalPrice = l.price * qty
        local totalItems = l.lot_size * qty
        if b.balance < totalPrice then
            rednet.send(cid,{ok=false,err="Need "..totalPrice.." sp, have "..b.balance.." sp"},PROTOCOL) return
        end
        -- Move items: market vault → buyer vault
        local moved = moveItem(MARKET_VAULT, acc.vault, l.item_name, totalItems)
        if moved < totalItems then
            if moved>0 then moveItem(acc.vault,MARKET_VAULT,l.item_name,moved) end
            rednet.send(cid,{ok=false,err="Item transfer failed, try again"},PROTOCOL) return
        end
        -- Push to player inventory directly
        local inVault = true
        if acc.invmanager and peripheral.isPresent(acc.invmanager) then
            local ok3,given = pcall(function()
                return peripheral.call(acc.invmanager,"addItemToPlayer",
                    acc.vaultDir or "back",{name=l.item_name,count=totalItems})
            end)
            if ok3 and given and given>0 then inVault=false end
        end
        -- Payment with tiered tax
        local taxPerLot  = calcMarketTax(l.price)
        local tax        = taxPerLot * qty
        local sellerGets = totalPrice - tax
        b.balance = b.balance - totalPrice
        local dn = l.display_name or l.item_name
        addBankLog(uname, "Bought "..totalItems.."x "..dn.." -"..totalPrice.."sp")
        local sb = getBankAcc(l.seller)
        sb.balance = sb.balance + sellerGets
        addBankLog(l.seller,"Sold "..totalItems.."x "..dn.." +"..sellerGets.."sp")
        addNotif(l.seller, uname.." bought "..totalItems.."x "..dn.." from your listing. +"..sellerGets.."sp (tax "..tax.."sp)")
        bankData.market_revenue = (bankData.market_revenue or 0) + tax
        if not bankData.market_sales then bankData.market_sales = {} end
        table.insert(bankData.market_sales, {ts=os.epoch("utc"), tax=tax})
        b.credit = math.min(900, b.credit + 1)
        l.stock = l.stock - qty
        if l.stock == 0 then l.out_of_stock_ts = os.epoch("utc") end
        saveMarket() saveBank()
        rednet.send(cid,{
            ok=true, item=dn, count=totalItems,
            price=totalPrice, tax=tax, seller_got=sellerGets,
            new_balance=b.balance, inVault=inVault,
        },PROTOCOL)
        print(uname.." bought "..totalItems.."x "..l.item_name.." from "..l.seller.." for "..totalPrice.." sp")

    elseif msg.type == "market_cancel" then
        local acc = accounts[uname]
        local l   = marketData.listings[tostring(msg.listing_id)]
        if not l then rednet.send(cid,{ok=false,err="Listing not found"},PROTOCOL) return end
        if l.seller~=uname and not sess.isAdmin then
            rednet.send(cid,{ok=false,err="Not your listing"},PROTOCOL) return
        end
        local returned = 0
        if l.stock > 0 and acc and acc.vault then
            returned = moveItem(MARKET_VAULT, acc.vault, l.item_name, l.stock * l.lot_size)
        end
        marketData.listings[tostring(msg.listing_id)] = nil
        saveMarket()
        rednet.send(cid,{ok=true,returned=returned},PROTOCOL)

    elseif msg.type == "market_edit_listing" then
        local l = marketData.listings[tostring(msg.listing_id)]
        if not l then rednet.send(cid,{ok=false,err="Listing not found"},PROTOCOL) return end
        if l.seller ~= uname then rednet.send(cid,{ok=false,err="Not your listing"},PROTOCOL) return end
        if msg.price ~= nil then
            l.price = math.max(0, math.floor(tonumber(msg.price) or 0))
        end
        if msg.lot_size ~= nil then
            if l.stock > 0 then
                rednet.send(cid,{ok=false,err="Drain stock before changing lot size"},PROTOCOL) return
            end
            l.lot_size = math.max(1, math.floor(tonumber(msg.lot_size) or 1))
        end
        saveMarket()
        rednet.send(cid,{ok=true,price=l.price,lot_size=l.lot_size},PROTOCOL)
        print(uname.." edited listing #"..tostring(l.id))

    elseif msg.type == "market_boost_listing" then
        local l = marketData.listings[tostring(msg.listing_id)]
        if not l then rednet.send(cid,{ok=false,err="Listing not found"},PROTOCOL) return end
        if l.seller ~= uname then rednet.send(cid,{ok=false,err="Not your listing"},PROTOCOL) return end
        local days = math.max(1, math.min(30, math.floor(tonumber(msg.days) or 1)))
        local cost = days * 10
        applyDepInterest(uname)
        local b = getBankAcc(uname)
        if b.balance < cost then
            rednet.send(cid,{ok=false,err="Need "..cost.." sp (have "..b.balance.." sp)"},PROTOCOL) return
        end
        b.balance = b.balance - cost
        bankData.market_revenue = (bankData.market_revenue or 0) + cost
        if not bankData.market_sales then bankData.market_sales = {} end
        local now = os.epoch("utc")
        table.insert(bankData.market_sales, {ts=now, tax=cost})
        l.boost_ts = math.max(now, l.boost_ts or 0) + days * 86400000
        local daysLeft = math.ceil((l.boost_ts - now) / 86400000)
        addBankLog(uname, "Boosted listing #"..l.id.." "..days.."d -"..cost.."sp")
        saveMarket() saveBank()
        rednet.send(cid,{ok=true,cost=cost,days_total=daysLeft},PROTOCOL)
        print(uname.." boosted listing #"..tostring(l.id).." for "..days.."d")

    elseif msg.type == "market_my_listings" then
        local mine = {}
        for _, l in pairs(marketData.listings) do
            if l.seller == uname then table.insert(mine, l) end
        end
        table.sort(mine, function(a,b) return (a.listed_ts or 0) > (b.listed_ts or 0) end)
        rednet.send(cid,{ok=true,listings=mine},PROTOCOL)

    elseif msg.type == "admin_bank_overview" then
        if not sess.isAdmin then rednet.send(cid, {err="Not authorized"}, PROTOCOL) return end
        local summary = {}
        for u2, b in pairs(bankData.accounts) do
            local loan = nil
            if b.loan then
                local now = os.epoch("utc")
                loan = { remaining=b.loan.remaining, overdue=now>b.loan.due_ts,
                         daysLeft=math.ceil((b.loan.due_ts-now)/86400000) }
            end
            table.insert(summary, {username=u2, balance=b.balance, credit=b.credit, loan=loan})
        end
        table.sort(summary, function(a,b) return a.username < b.username end)
        local vspurs       = countVaultValue(BANK_VAULT)
        local tdep         = totalDeposits()
        local tloans       = totalLoans()
        local daily_loan_int = 0
        local daily_dep_int  = 0
        for _, b in pairs(bankData.accounts) do
            if b.loan then
                daily_loan_int = daily_loan_int + math.ceil(b.loan.remaining * (b.loan.rate / 100))
            end
            if (b.balance or 0) > 0 then
                daily_dep_int = daily_dep_int + math.floor(b.balance * 0.02)
            end
        end
        local now_ms = os.epoch("utc")
        local cutoff = now_ms - 86400000
        local mkt24  = 0
        local pruned_sales = {}
        for _, s in ipairs(bankData.market_sales or {}) do
            if s.ts >= cutoff then
                mkt24 = mkt24 + s.tax
                table.insert(pruned_sales, s)
            end
        end
        bankData.market_sales = pruned_sales
        rednet.send(cid, {
            ok=true, users=summary,
            total_dep      = tdep,
            total_loans    = tloans,
            vault_spurs    = vspurs,
            bank_balance   = vspurs - tdep,
            daily_loan_int = daily_loan_int,
            daily_dep_int  = daily_dep_int,
            market_revenue = mkt24,
        }, PROTOCOL)

    -- ── Coinflip handlers ─────────────────────────────────────────────────────
    elseif msg.type == "coinflip_create" then
        local wager = math.max(1, math.floor(tonumber(msg.wager) or 0))
        applyDepInterest(uname)
        local b = getBankAcc(uname)
        if b.balance < wager then
            rednet.send(cid,{ok=false,err="Need "..wager.." sp (have "..b.balance.." sp)"},PROTOCOL) return
        end
        b.balance = b.balance - wager
        if not bankData.coinflips    then bankData.coinflips    = {} end
        if not bankData.next_flip_id then bankData.next_flip_id = 1  end
        local fid = bankData.next_flip_id
        bankData.next_flip_id = fid + 1
        bankData.coinflips[tostring(fid)] = {
            id=fid, creator=uname, wager=wager, created_ts=os.epoch("utc"),
        }
        addBankLog(uname, "Coinflip #"..fid.." created, wagered "..wager.." sp")
        saveBank()
        rednet.send(cid,{ok=true,id=fid,wager=wager},PROTOCOL)
        print(uname.." created coinflip #"..fid.." for "..wager.." sp")

    elseif msg.type == "coinflip_list" then
        local open = {}
        for _, f in pairs(bankData.coinflips or {}) do
            if f.creator ~= uname then
                table.insert(open, {id=f.id, creator=f.creator, wager=f.wager, created_ts=f.created_ts})
            end
        end
        table.sort(open, function(a,b) return (a.created_ts or 0) > (b.created_ts or 0) end)
        rednet.send(cid,{ok=true,flips=open},PROTOCOL)

    elseif msg.type == "coinflip_join" then
        local f = (bankData.coinflips or {})[tostring(msg.flip_id)]
        if not f then rednet.send(cid,{ok=false,err="Coinflip not found (already taken?)"},PROTOCOL) return end
        if f.creator == uname then rednet.send(cid,{ok=false,err="Cannot join your own coinflip"},PROTOCOL) return end
        applyDepInterest(uname)
        local b = getBankAcc(uname)
        if b.balance < f.wager then
            rednet.send(cid,{ok=false,err="Need "..f.wager.." sp (have "..b.balance.." sp)"},PROTOCOL) return
        end
        b.balance = b.balance - f.wager
        math.randomseed(os.epoch("utc"))
        local creatorWins = math.random() > 0.5
        local winner = creatorWins and f.creator or uname
        local loser  = creatorWins and uname or f.creator
        local pot = f.wager * 2
        local houseCut = math.max(1, math.floor(pot * 0.10))
        local prize = pot - houseCut
        local wb = getBankAcc(winner)
        wb.balance = wb.balance + prize
        bankData.market_revenue = (bankData.market_revenue or 0) + houseCut
        if not bankData.market_sales then bankData.market_sales = {} end
        table.insert(bankData.market_sales, {ts=os.epoch("utc"), tax=houseCut})
        local youWon = (winner == uname)
        addBankLog(uname,    "Coinflip #"..f.id.." vs "..f.creator.." "..(youWon and "WON +"..prize or "lost -"..f.wager).." sp")
        addBankLog(f.creator,"Coinflip #"..f.id.." vs "..uname.." "..(creatorWins and "WON +"..prize or "lost -"..f.wager).." sp")
        addNotif(uname,     "Coinflip #"..f.id.." vs "..f.creator..": "..(youWon and "YOU WON! +"..prize.."sp" or "you lost. -"..f.wager.."sp"))
        addNotif(f.creator, "Coinflip #"..f.id..": "..uname.." joined your flip! "..(creatorWins and "YOU WON! +"..prize.."sp" or "you lost. -"..f.wager.."sp"))
        bankData.coinflips[tostring(msg.flip_id)] = nil
        saveBank()
        rednet.send(cid,{
            ok=true, winner=winner, loser=loser, you_won=youWon,
            prize=prize, wager=f.wager, house_cut=houseCut, new_balance=b.balance,
        },PROTOCOL)
        print("Coinflip #"..f.id..": "..winner.." beat "..loser.." prize="..prize.." house="..houseCut)

    elseif msg.type == "coinflip_cancel" then
        local f = (bankData.coinflips or {})[tostring(msg.flip_id)]
        if not f then rednet.send(cid,{ok=false,err="Coinflip not found"},PROTOCOL) return end
        if f.creator ~= uname then rednet.send(cid,{ok=false,err="Not your coinflip"},PROTOCOL) return end
        local b = getBankAcc(uname)
        b.balance = b.balance + f.wager
        addBankLog(uname, "Coinflip #"..f.id.." cancelled, returned "..f.wager.." sp")
        bankData.coinflips[tostring(msg.flip_id)] = nil
        saveBank()
        rednet.send(cid,{ok=true,returned=f.wager},PROTOCOL)

    elseif msg.type == "coinflip_my_bets" then
        local mine = {}
        for _, f in pairs(bankData.coinflips or {}) do
            if f.creator == uname then
                table.insert(mine, {id=f.id, wager=f.wager, created_ts=f.created_ts})
            end
        end
        table.sort(mine, function(a,b) return (a.created_ts or 0) > (b.created_ts or 0) end)
        rednet.send(cid,{ok=true,bets=mine},PROTOCOL)
    end
end

print("Cloud server v3 online")
print("Peripherals: " .. table.concat(peripheral.getNames(), ", "))
pruneStaleListings()
local _origRednetSend = rednet.send
while true do
    local cid, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" and msg._seq then
        local seq = msg._seq
        rednet.send = function(id, data, proto)
            if type(data) == "table" then data._seq = seq end
            _origRednetSend(id, data, proto)
        end
        handle(cid, msg)
        rednet.send = _origRednetSend
    else
        handle(cid, msg)
    end
end