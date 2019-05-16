ESX.Trace = function(str)
	if Config.EnableDebug then
		print('ESX> ' .. str)
	end
end

ESX.SetTimeout = function(msec, cb)
	local id = ESX.TimeoutCount + 1

	SetTimeout(msec, function()
		if ESX.CancelledTimeouts[id] then
			ESX.CancelledTimeouts[id] = nil
		else
			cb()
		end
	end)

	ESX.TimeoutCount = id

	return id
end

ESX.ClearTimeout = function(id)
	ESX.CancelledTimeouts[id] = true
end

ESX.RegisterServerCallback = function(name, cb)
	ESX.ServerCallbacks[name] = cb
end

ESX.TriggerServerCallback = function(name, requestId, source, cb, ...)
	if ESX.ServerCallbacks[name] ~= nil then
		ESX.ServerCallbacks[name](source, cb, ...)
	else
		print('es_extended: TriggerServerCallback => [' .. name .. '] does not exist')
	end
end

ESX.SavePlayer = function(xPlayer, cb)
	local asyncTasks = {}
	xPlayer.setLastPosition(xPlayer.getCoords())

	-- User accounts
	for i=1, #xPlayer.accounts, 1 do
		if ESX.LastPlayerData[xPlayer.source].accounts[xPlayer.accounts[i].name] ~= xPlayer.accounts[i].money then
			table.insert(asyncTasks, function(cb)
				MySQL.Async.execute('UPDATE user_accounts SET `money` = @money WHERE identifier = @identifier AND name = @name', {
					['@money']      = xPlayer.accounts[i].money,
					['@identifier'] = xPlayer.identifier,
					['@name']       = xPlayer.accounts[i].name
				}, function(rowsChanged)
					cb()
				end)
			end)

			ESX.LastPlayerData[xPlayer.source].accounts[xPlayer.accounts[i].name] = xPlayer.accounts[i].money
		end
	end

	-- Inventory items
	for i=1, #xPlayer.inventory, 1 do
		if ESX.LastPlayerData[xPlayer.source].items[xPlayer.inventory[i].name] ~= xPlayer.inventory[i].count then
			table.insert(asyncTasks, function(cb)
				MySQL.Async.execute('UPDATE user_inventory SET `count` = @count WHERE identifier = @identifier AND item = @item', {
					['@count']      = xPlayer.inventory[i].count,
					['@identifier'] = xPlayer.identifier,
					['@item']       = xPlayer.inventory[i].name
				}, function(rowsChanged)
					cb()
				end)
			end)

			ESX.LastPlayerData[xPlayer.source].items[xPlayer.inventory[i].name] = xPlayer.inventory[i].count
		end
	end

	-- Job, loadout and position
	table.insert(asyncTasks, function(cb)
		MySQL.Async.execute('UPDATE users SET `job` = @job, `job_grade` = @job_grade, `loadout` = @loadout, `position` = @position WHERE identifier = @identifier', {
			['@job']        = xPlayer.job.name,
			['@job_grade']  = xPlayer.job.grade,
			['@loadout']    = json.encode(xPlayer.getLoadout()),
			['@position']   = json.encode(xPlayer.getLastPosition()),
			['@identifier'] = xPlayer.identifier
		}, function(rowsChanged)
			cb()
		end)
	end)

	Async.parallel(asyncTasks, function(results)
		RconPrint('[SAVED] ' .. xPlayer.name .. "^7\n")

		if cb ~= nil then
			cb()
		end
	end)
end

ESX.SavePlayers = function(cb)
	local asyncTasks = {}
	local xPlayers   = ESX.GetPlayers()

	for i=1, #xPlayers, 1 do
		table.insert(asyncTasks, function(cb)
			local xPlayer = ESX.GetPlayerFromId(xPlayers[i])
			ESX.SavePlayer(xPlayer, cb)
		end)
	end

	Async.parallelLimit(asyncTasks, 8, function(results)
		RconPrint('[SAVED] All players' .. "\n")

		if cb ~= nil then
			cb()
		end
	end)
end

ESX.StartDBSync = function()
	function saveData()
		ESX.SavePlayers()
		SetTimeout(10 * 60 * 1000, saveData)
	end

	SetTimeout(10 * 60 * 1000, saveData)
end

ESX.GetPlayers = function()
	local sources = {}

	for k,v in pairs(ESX.Players) do
		table.insert(sources, k)
	end

	return sources
end


ESX.GetPlayerFromId = function(source)
	return ESX.Players[tonumber(source)]
end



ESX.GetPlayerFromIdentifier = function(identifier)
	for k,v in pairs(ESX.Players) do
		if v.identifier == identifier then
			return v
		end
	end
end

ESX.RegisterUsableItem = function(item, cb)
	ESX.UsableItemsCallbacks[item] = cb
end

ESX.RegisterUsableItemType = function(type, cb)
	ESX.UsableItemsCallbacks[type] = cb
end

ESX.UseItem = function(source, item, type, count)
	print("USE ITEM")
	print(item)
	print(type)
	if ESX.UsableItemsCallbacks[item] then
		ESX.UsableItemsCallbacks[item](source)
	elseif ESX.UsableItemsCallbacks[type] then
		ESX.UsableItemsCallbacks[type](source,item,count)
	end
end

ESX.GetItemLabel = function(item)
	if ESX.Items[item] ~= nil then
		return ESX.Items[item].label
	end
end

ESX.GetPickups = function()
	return ESX.Pickups
end

ESX.GetPickupInventory = function(player,coords)
	local pickupId = genCoordId(coords)
	local pickup = ESX.Pickups[pickupId]
	local inventory = {}
	local money = 0
	local weapons = {}
	local accounts = {}
	if pickup ~= nil and pickup ~= 0 then
		for k,item in pairs(pickup.items) do
			if item.type == 'item_standard' then		
				table.insert(inventory,item)
			elseif item.type == 'item_money' then
				money = money + item.count
			elseif item.type == 'item_account' then
				table.insert(accounts,item)
			elseif item.type == 'item_weapon' then
				table.insert(weapons,item)
			end
		end
	end


	return {
		inventory = inventory,
		money = money,
		accounts = accounts,
		weapons = weapons
	}
end

-- overwrite item count inside a pickup bag
ESX.OverwritePickup = function(pickupId, name, count, player)
	local pickup = ESX.Pickups[pickupId]

	if pickup ~= nil and pickup ~= 0 then
		pickup.items[name].count = count	
		ESX.Pickups[pickupId] = pickup
		ESX.PickupId = pickupId		
	end
end

-- create and add items to pickups bag
ESX.CreatePickup = function(type, name, count, label, player, coords)
	local pickupId = genCoordId(coords)  -- lasciamo perdere le logiche di sta roba
	local pickup = ESX.Pickups[pickupId]
	local item = {
		type  = type,
		name  = name,
		label = label,
		count = count
	}

	if pickup ~= nil and pickup ~= 0 then
		local _item = pickup.items[name]
		if _item ~= nil and _item ~= 0 then
			item.count = item.count + _item.count
			pickup.items[name] = item	
		else
			pickup.items[name] = item
		end
		ESX.Pickups[pickupId] = pickup
		ESX.PickupId = pickupId
	else
		pickup = {
			coords = coords,
			items = {}
		}
		pickup.items[name] = item
		ESX.Pickups[pickupId] = pickup
		TriggerClientEvent('esx:pickup', -1, pickupId, player, coords)
		ESX.PickupId = pickupId
	end
end

-- restore bag for connecting clients
ESX.RestorePickup = function(pickupId, player, coords)
	print("RestorePickup : " .. pickupId)
	TriggerClientEvent('esx:pickup', player, pickupId, player, coords)
	ESX.PickupId = pickupId
end


ESX.DoesJobExist = function(job, grade)
	grade = tostring(grade)

	if job and grade then
		if ESX.Jobs[job] and ESX.Jobs[job].grades[grade] then
			return true
		end
	end

	return false
end