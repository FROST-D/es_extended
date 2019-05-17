AddEventHandler('es:playerLoaded', function(source, _player)
	local _source = source
	local tasks   = {}

	local userData = {
		accounts     = {},
		inventory    = {},
		job          = {},
		loadout      = {},
		loadoutAmmo	 = {},
		playerName   = GetPlayerName(_source),
		lastPosition = nil
	}

	TriggerEvent('es:getPlayerFromId', _source, function(player)
		-- Update user name in DB
		table.insert(tasks, function(cb)
			MySQL.Async.execute('UPDATE `users` SET `name` = @name WHERE `identifier` = @identifier', {
				['@identifier'] = player.getIdentifier(),
				['@name'] = userData.playerName
			}, function(rowsChanged)
				cb()
			end)
		end)

		-- Get accounts
		table.insert(tasks, function(cb)
			MySQL.Async.fetchAll('SELECT * FROM `user_accounts` WHERE `identifier` = @identifier', {
				['@identifier'] = player.getIdentifier()
			}, function(accounts)
				for i=1, #Config.Accounts, 1 do
					for j=1, #accounts, 1 do
						if accounts[j].name == Config.Accounts[i] then
							table.insert(userData.accounts, {
								name  = accounts[j].name,
								money = accounts[j].money,
								label = Config.AccountLabels[accounts[j].name]
							})
						end

						break
					end
				end

				cb()
			end)
		end)

		-- Get inventory
		table.insert(tasks, function(cb)

			MySQL.Async.fetchAll('SELECT * FROM `user_inventory` WHERE `identifier` = @identifier', {
				['@identifier'] = player.getIdentifier()
			}, function(inventory)
				local tasks2 = {}

				for i=1, #inventory do
					local item = ESX.Items[inventory[i].item]

					if item then
						local _na = inventory[i].item
						local _type = _na
						if _na:sub(1, 7) == "WEAPON_" then
							_type = "item_weapon_packed"
						elseif _na:sub(1, 5) == "AMMO_" then
							_type = "item_ammo"				
						end
						-- item_weapon_packed 
						-- item_ammo
						table.insert(userData.inventory, {
							name = inventory[i].item,
							count = inventory[i].count,
							label = item.label,
							limit = item.limit,
							usable = ESX.UsableItemsCallbacks[_type], -- if we have a callback means the item can be used
							rare = item.rare,
							canRemove = item.canRemove
						})
					else
						print(('es_extended: invalid item "%s" ignored!'):format(inventory[i].item))
					end
				end

				for k,v in pairs(ESX.Items) do
					local found = false

					for j=1, #userData.inventory do
						if userData.inventory[j].name == k then
							found = true
							break
						end
					end

					if not found then
						local _na = k
						local _type = _na
						if _na:sub(1, 7) == "WEAPON_" then
							_type = "item_weapon_packed"
						elseif _na:sub(1, 5) == "AMMO_" then
							_type = "item_ammo"				
						end
						table.insert(userData.inventory, {
							name = k,
							count = 0,
							label = ESX.Items[k].label,
							limit = ESX.Items[k].limit,
							usable = ESX.UsableItemsCallbacks[_type] ~= nil,
							rare = ESX.Items[k].rare,
							canRemove = ESX.Items[k].canRemove
						})

						local scope = function(item, identifier)
							table.insert(tasks2, function(cb2)
								MySQL.Async.execute('INSERT INTO user_inventory (identifier, item, count) VALUES (@identifier, @item, @count)', {
									['@identifier'] = identifier,
									['@item'] = item,
									['@count'] = 0
								}, function(rowsChanged)
									cb2()
								end)
							end)
						end

						scope(k, player.getIdentifier())
					end

				end

				Async.parallelLimit(tasks2, 5, function(results) end)

				table.sort(userData.inventory, function(a,b)
					return a.label < b.label
				end)
				cb()
			end)

		end)

		-- Get job and loadout
		table.insert(tasks, function(cb)

			local tasks2 = {}

			-- Get job name, grade and last position
			table.insert(tasks2, function(cb2)

				MySQL.Async.fetchAll('SELECT job, job_grade, loadout, position FROM `users` WHERE `identifier` = @identifier', {
					['@identifier'] = player.getIdentifier()
				}, function(result)
					local job, grade = result[1].job, tostring(result[1].job_grade)

					if ESX.DoesJobExist(job, grade) then
						local jobObject, gradeObject = ESX.Jobs[job], ESX.Jobs[job].grades[grade]

						userData.job = {}

						userData.job.id    = jobObject.id
						userData.job.name  = jobObject.name
						userData.job.label = jobObject.label

						userData.job.grade        = tonumber(grade)
						userData.job.grade_name   = gradeObject.name
						userData.job.grade_label  = gradeObject.label
						userData.job.grade_salary = gradeObject.salary

						userData.job.skin_male    = {}
						userData.job.skin_female  = {}

						if gradeObject.skin_male ~= nil then
							userData.job.skin_male = json.decode(gradeObject.skin_male)
						end
			
						if gradeObject.skin_female ~= nil then
							userData.job.skin_female = json.decode(gradeObject.skin_female)
						end
					else
						print(('es_extended: %s had an unknown job [job: %s, grade: %s], setting as unemployed!'):format(player.getIdentifier(), job, grade))

						local job, grade = 'unemployed', '0'
						local jobObject, gradeObject = ESX.Jobs[job], ESX.Jobs[job].grades[grade]

						userData.job = {}

						userData.job.id    = jobObject.id
						userData.job.name  = jobObject.name
						userData.job.label = jobObject.label
			
						userData.job.grade        = tonumber(grade)
						userData.job.grade_name   = gradeObject.name
						userData.job.grade_label  = gradeObject.label
						userData.job.grade_salary = gradeObject.salary
			
						userData.job.skin_male    = {}
						userData.job.skin_female  = {}
					end

					if result[1].loadout ~= nil then
						userData.loadout = json.decode(result[1].loadout)

						-- Compatibility with old loadouts prior to components update
						for k,v in ipairs(userData.loadout) do
							local ammoName = ESX.GetWeaponAmmo2(v.name)
							if ammoName ~= nil then
								userData.loadoutAmmo[ammoName] = v.ammo
							end

							if v.components == nil then
								v.components = {}
							end
						end
					end

					if result[1].position ~= nil then
						userData.lastPosition = json.decode(result[1].position)
					end

					cb2()
				end)

			end)

			Async.series(tasks2, cb)

		end)

		-- Run Tasks
		Async.parallel(tasks, function(results)
			local xPlayer = CreateExtendedPlayer(player, userData.accounts, userData.inventory, userData.job, userData.loadout, userData.playerName, userData.lastPosition, userData.loadoutAmmo)

			xPlayer.getMissingAccounts(function(missingAccounts)
				if #missingAccounts > 0 then

					for i=1, #missingAccounts, 1 do
						table.insert(xPlayer.accounts, {
							name  = missingAccounts[i],
							money = 0,
							label = Config.AccountLabels[missingAccounts[i]]
						})
					end

					xPlayer.createAccounts(missingAccounts)
				end

				ESX.Players[_source] = xPlayer

				TriggerEvent('esx:playerLoaded', _source, xPlayer)

				TriggerClientEvent('esx:playerLoaded', _source, {
					identifier   = xPlayer.identifier,
					accounts     = xPlayer.getAccounts(),
					inventory    = xPlayer.getInventory(),
					job          = xPlayer.getJob(),
					loadout      = xPlayer.getLoadout(),
					lastPosition = xPlayer.getLastPosition(),
					money        = xPlayer.getMoney()
				})

				xPlayer.displayMoney(xPlayer.getMoney())

				print("USERDATA")
				print(ESX.DumpTable(xPlayer.getAccounts()))
				print("getInventory")
				print(ESX.DumpTable(xPlayer.getInventory()))
				print("getJob")
				print(ESX.DumpTable(xPlayer.getJob()))
				print("getLoadout")
				print(ESX.DumpTable(xPlayer.getLoadout()))
				print("getMoney")
				print(ESX.DumpTable(xPlayer.getMoney()))
			end)
		end)

	end)
end)

AddEventHandler('playerDropped', function(reason)
	local _source = source
	local xPlayer = ESX.GetPlayerFromId(_source)

	if xPlayer then
		TriggerEvent('esx:playerDropped', _source, reason)

		ESX.SavePlayer(xPlayer, function()
			ESX.Players[_source] = nil
			ESX.LastPlayerData[_source] = nil
		end)
	end
end)

RegisterServerEvent('esx:updateLoadout')
AddEventHandler('esx:updateLoadout', function(loadout)
	local xPlayer = ESX.GetPlayerFromId(source)
	xPlayer.loadout = loadout
end)

RegisterServerEvent('esx:updateLastPosition')
AddEventHandler('esx:updateLastPosition', function(position)
	local xPlayer = ESX.GetPlayerFromId(source)
	xPlayer.setLastPosition(position)
end)

RegisterServerEvent('esx:giveInventoryItem')
AddEventHandler('esx:giveInventoryItem', function(target, type, itemName, itemCount)
	local _source = source

	local sourceXPlayer = ESX.GetPlayerFromId(_source)
	local targetXPlayer = ESX.GetPlayerFromId(target)

	if type == 'item_standard' or type == 'item_weapon_packed' or type == 'item_ammo' then

		local sourceItem = sourceXPlayer.getInventoryItem(itemName)
		local targetItem = targetXPlayer.getInventoryItem(itemName)

		if itemCount > 0 and sourceItem.count >= itemCount then

			if targetItem.limit ~= -1 and (targetItem.count + itemCount) > targetItem.limit then
				TriggerClientEvent('esx:showNotification', _source, _U('ex_inv_lim', targetXPlayer.name))
			else
				sourceXPlayer.removeInventoryItem(itemName, itemCount)
				targetXPlayer.addInventoryItem   (itemName, itemCount)
				
				TriggerClientEvent('esx:showNotification', _source, _U('gave_item', itemCount, ESX.Items[itemName].label, targetXPlayer.name))
				TriggerClientEvent('esx:showNotification', target,  _U('received_item', itemCount, ESX.Items[itemName].label, sourceXPlayer.name))
			end

		else
			TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_quantity'))
		end

	elseif type == 'item_money' then

		if itemCount > 0 and sourceXPlayer.getMoney() >= itemCount then
			sourceXPlayer.removeMoney(itemCount)
			targetXPlayer.addMoney   (itemCount)

			TriggerClientEvent('esx:showNotification', _source, _U('gave_money', ESX.Math.GroupDigits(itemCount), targetXPlayer.name))
			TriggerClientEvent('esx:showNotification', target,  _U('received_money', ESX.Math.GroupDigits(itemCount), sourceXPlayer.name))
		else
			TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_amount'))
		end

	elseif type == 'item_account' then

		if itemCount > 0 and sourceXPlayer.getAccount(itemName).money >= itemCount then
			sourceXPlayer.removeAccountMoney(itemName, itemCount)
			targetXPlayer.addAccountMoney   (itemName, itemCount)

			TriggerClientEvent('esx:showNotification', _source, _U('gave_account_money', ESX.Math.GroupDigits(itemCount), Config.AccountLabels[itemName], targetXPlayer.name))
			TriggerClientEvent('esx:showNotification', target,  _U('received_account_money', ESX.Math.GroupDigits(itemCount), Config.AccountLabels[itemName], sourceXPlayer.name))
		else
			TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_amount'))
		end

	elseif type == 'item_weapon' then

		if not targetXPlayer.hasWeapon(itemName) then
			sourceXPlayer.removeWeapon(itemName)
			targetXPlayer.addWeapon(itemName, itemCount)

			local weaponLabel = ESX.GetWeaponLabel(itemName)

			if itemCount > 0 then
				TriggerClientEvent('esx:showNotification', _source, _U('gave_weapon_ammo', weaponLabel, itemCount, targetXPlayer.name))
				TriggerClientEvent('esx:showNotification', target,  _U('received_weapon_ammo', weaponLabel, itemCount, sourceXPlayer.name))
			else
				TriggerClientEvent('esx:showNotification', _source, _U('gave_weapon', weaponLabel, targetXPlayer.name))
				TriggerClientEvent('esx:showNotification', target,  _U('received_weapon', weaponLabel, sourceXPlayer.name))
			end
		else
			TriggerClientEvent('esx:showNotification', _source, _U('gave_weapon_hasalready', targetXPlayer.name, weaponLabel))
			TriggerClientEvent('esx:showNotification', _source, _U('received_weapon_hasalready', sourceXPlayer.name, weaponLabel))
		end

	end
end)

RegisterServerEvent('esx:createPickupTestLockpick')
AddEventHandler('esx:createPickupTestLockpick', function(coords)
	local pickupId = genCoordId(coords)
	local pickupTable = ESX.Pickups[id]
	ESX.CreatePickup('item_standard', 'lockpick', 1, 'STO CAZZO', source, coords)
end)

RegisterServerEvent('esx:removeInventoryItem')
AddEventHandler('esx:removeInventoryItem', function(type, itemName, itemCount, coords)
	local _source = source
	local _coords = coords

	if type == 'item_standard' or type == 'item_weapon_packed' or type == 'item_ammo' then

		if itemCount == nil or itemCount < 1 then
			TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_quantity'))
		else
			local xPlayer = ESX.GetPlayerFromId(source)
			local xItem = xPlayer.getInventoryItem(itemName)

			if (itemCount > xItem.count) then
				itemCount = xItem.count
			end
			if (itemCount > xItem.count or xItem.count < 1) then
				TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_quantity'))
			else
				xPlayer.removeInventoryItem(itemName, itemCount)

				local pickupLabel = xItem.label
				ESX.CreatePickup(type, itemName, itemCount, pickupLabel, _source, _coords)
				TriggerClientEvent('esx:showNotification', _source, _U('threw_standard', itemCount, xItem.label))
			end
		end

	elseif type == 'item_money' then

		if itemCount == nil or itemCount < 1 then
			TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_amount'))
		else
			local xPlayer = ESX.GetPlayerFromId(source)
			local playerCash = xPlayer.getMoney()

			if (itemCount > playerCash or playerCash < 1) then
				TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_amount'))
			else
				xPlayer.removeMoney(itemCount)

				local pickupLabel = ('~y~%s~s~ [~g~%s~s~]'):format(_U('cash'), _U('locale_currency', ESX.Math.GroupDigits(itemCount)))
				ESX.CreatePickup('item_money', 'money', itemCount, pickupLabel, _source, _coords)
				TriggerClientEvent('esx:showNotification', _source, _U('threw_money', ESX.Math.GroupDigits(itemCount)))
			end
		end

	elseif type == 'item_account' then

		if itemCount == nil or itemCount < 1 then
			TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_amount'))
		else
			local xPlayer = ESX.GetPlayerFromId(source)
			local account = xPlayer.getAccount(itemName)

			if (itemCount > account.money or account.money < 1) then
				TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_amount'))
			else
				xPlayer.removeAccountMoney(itemName, itemCount)

				local pickupLabel = ('~y~%s~s~ [~g~%s~s~]'):format(account.label, _U('locale_currency', ESX.Math.GroupDigits(itemCount)))
				ESX.CreatePickup('item_account', itemName, itemCount, pickupLabel, _source, _coords)
				TriggerClientEvent('esx:showNotification', _source, _U('threw_account', ESX.Math.GroupDigits(itemCount), string.lower(account.label)))
			end
		end

	elseif type == 'item_weapon' then
		--weapon we drop only the weapon, ammos will be a separate obj
		local xPlayer = ESX.GetPlayerFromId(source)
		--local loadout = xPlayer.getLoadout()
		-- for i=1, #loadout, 1 do
		-- 	if loadout[i].name == itemName then
		-- 		itemCount = loadout[i].ammo
		-- 		break
		-- 	end
		-- end
		if itemCount == nil or itemCount < 1 then
			TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_quantity'))
		else
			local xItem = xPlayer.getInventoryItem(itemName)

			if (xItem) then 
				--we have a free weapon inside invetory
				if (itemCount > xItem.count) then
					itemCount = xItem.count
				end
				if (itemCount <= xItem.count and xItem.count > 0) then
					xPlayer.removeInventoryItem(itemName, itemCount)
					local pickupLabel = xItem.label
					ESX.CreatePickup('item_weapon_packed', itemName, itemCount, pickupLabel, _source, _coords)
					TriggerClientEvent('esx:showNotification', _source, _U('threw_standard', itemCount, xItem.label))
				elseif (xPlayer.hasWeapon(itemName)) then
					--we don't have free weapon inside inventory get it from loadout
					xPlayer.removeWeapon(itemName)
					--local pickupLabel = ('~y~%s~s~ [~b~%s~s~]'):format(ESX.GetWeaponLabel(itemName), itemCount)
					local pickupLabel = ESX.GetWeaponLabel(itemName)
					ESX.CreatePickup('item_weapon_packed', itemName, 1, pickupLabel, _source, _coords)
					TriggerClientEvent('esx:showNotification', _source, _U('threw_standard', itemCount, pickupLabel))	
				else
					TriggerClientEvent('esx:showNotification', _source, _U('imp_invalid_quantity'))
				end
			end
		end
	end
end)

RegisterServerEvent('esx:useItem')
AddEventHandler('esx:useItem', function(itemName,type,count)
	local xPlayer = ESX.GetPlayerFromId(source)
	if (count == nil) then 
		count = 0 
	end
	if type == 'item_standard' or type == 'item_weapon_packed' or type == 'item_ammo' then
		local item   = xPlayer.getInventoryItem(itemName)
		if item.count > 0 then 
			ESX.UseItem(source, itemName, type, count)
		else
			TriggerClientEvent('esx:showNotification', xPlayer.source, _U('act_imp'))
		end
	elseif type == 'item_weapon' then
		if xPlayer.hasWeapon(itemName) then
			ESX.UseItem(source, itemName, type, count)
		else
			TriggerClientEvent('esx:showNotification', xPlayer.source, _U('act_imp'))
		end
	end
end)


RegisterServerEvent('esx:onPickup')
AddEventHandler('esx:onPickup', function(coords)
	local _source = source
	local id = genCoordId(coords) -- lasciamo perdere le logiche di sta roba
	local pickupTable = ESX.Pickups[id]
	local xPlayer = ESX.GetPlayerFromId(_source)
	if pickupTable ~= nil and pickupTable ~= 0 then
		local removedItems = 0
		local processedItems = 0
	
		for k,pickup in pairs(pickupTable.items) do
			processedItems = processedItems + 1
			if pickup.type == 'item_standard' or pickup.type == 'item_weapon_packed' or pickup.type == 'item_ammo' then
		
				local item      = xPlayer.getInventoryItem(pickup.name)
				local canTake   = ((item.limit == -1) and (pickup.count)) or ((item.limit - item.count > 0) and (item.limit - item.count)) or 0
				local total     = pickup.count < canTake and pickup.count or canTake
				local remaining = pickup.count - total

				print("canTake : " .. canTake)
				print("total : " .. total)
				print("remaining : " .. remaining)


				if total > 0 then
					xPlayer.addInventoryItem(pickup.name, total)
				end
		
				if remaining > 0 then
					TriggerClientEvent('esx:showNotification', _source, _U('cannot_pickup_room', item.label))		
					local pickupLabel = ('~y~%s~s~ [~b~%s~s~]'):format(item.label, remaining)
					ESX.OverwritePickup(id, pickup.name, remaining, _source)
				else
					removedItems = removedItems + 1
					pickupTable.items[k] = nil
				end
			elseif pickup.type == 'item_money' then
				xPlayer.addMoney(pickup.count)
				removedItems = removedItems + 1
				pickupTable.items[k] = nil
			elseif pickup.type == 'item_account' then
				xPlayer.addAccountMoney(pickup.name, pickup.count)
				removedItems = removedItems + 1
				pickupTable.items[k] = nil
			elseif pickup.type == 'item_account' then
				xPlayer.addAccountMoney(pickup.name, pickup.count)
				removedItems = removedItems + 1
				pickupTable.items[k] = nil
			elseif pickup.type == 'item_weapon' then
				print(pickup.name)
				local item      = xPlayer.getInventoryItem(pickup.name)
				local canTake   = ((item.limit == -1) and (pickup.count)) or ((item.limit - item.count > 0) and (item.limit - item.count)) or 0
				local total     = pickup.count < canTake and pickup.count or canTake
				local remaining = pickup.count - total

				print("canTake : " .. canTake)
				print("total : " .. total)
				print("remaining : " .. remaining)


				if total > 0 then
					xPlayer.addInventoryItem(pickup.name, total)
				end
		
				if remaining > 0 then
					TriggerClientEvent('esx:showNotification', _source, _U('cannot_pickup_room', item.label))		
					local pickupLabel = ('~y~%s~s~ [~b~%s~s~]'):format(item.label, remaining)
					ESX.OverwritePickup(id, pickup.name, remaining, _source)
				else
					removedItems = removedItems + 1
					pickupTable.items[k] = nil
				end		
			end
		end
		if removedItems == processedItems then
			TriggerClientEvent('esx:removePickup', -1, id)
			ESX.Pickups[id] = nil
		end
	end
end)

RegisterServerEvent('esx:onTakeFromPickup')
AddEventHandler('esx:onTakeFromPickup', function(coords,itemType,itemName,itemCount)
	local _source = source
	local id = genCoordId(coords) -- lasciamo perdere le logiche di sta roba
	local pickupTable = ESX.Pickups[id]
	local xPlayer = ESX.GetPlayerFromId(_source)

	if pickupTable ~= nil and pickupTable ~= 0 then
		local totalItems = #pickupTable.items
	
		for k,pickup in pairs(pickupTable.items) do
			if(pickup.name == itemName) then
				if pickup.type == 'item_standard' or pickup.type == 'item_weapon_packed' or pickup.type == 'item_ammo' then	
					local item      = xPlayer.getInventoryItem(pickup.name)
					local canTake   = ((item.limit == -1) and (itemCount)) or ((item.limit - item.count > 0) and (item.limit - item.count)) or 0
					local total     = itemCount < canTake and itemCount or canTake
					local remaining = itemCount - total

					print("canTake : " .. canTake)
					print("total : " .. total)
					print("remaining : " .. remaining)
					if total > 0 then
						xPlayer.addInventoryItem(pickup.name, total)
					end
			
					if remaining > 0 then
						TriggerClientEvent('esx:showNotification', _source, _U('cannot_pickup_room', item.label))		
						local pickupLabel = ('~y~%s~s~ [~b~%s~s~]'):format(item.label, remaining)
						ESX.OverwritePickup(id, pickup.name, remaining, _source)
					else
						totalItems = totalItems - 1
						pickupTable.items[k] = nil
					end
				elseif pickup.type == 'item_money' then
					xPlayer.addMoney(itemCount)
					totalItems = totalItems - 1
					pickupTable.items[k] = nil
				elseif pickup.type == 'item_account' then
					xPlayer.addAccountMoney(pickup.name, itemCount)
					totalItems = totalItems - 1
					pickupTable.items[k] = nil
				elseif pickup.type == 'item_account' then
					xPlayer.addAccountMoney(pickup.name, itemCount)
					totalItems = totalItems - 1
					pickupTable.items[k] = nil
				elseif pickup.type == 'item_weapon' then
					print(pickup.name)
					local item      = xPlayer.getInventoryItem(pickup.name)
					local canTake   = ((item.limit == -1) and (itemCount)) or ((item.limit - item.count > 0) and (item.limit - item.count)) or 0
					local total     = itemCount < canTake and itemCount or canTake
					local remaining = itemCount - total

					print("canTake : " .. canTake)
					print("total : " .. total)
					print("remaining : " .. remaining)


					if total > 0 then
						xPlayer.addInventoryItem(pickup.name, total)
					end
			
					if remaining > 0 then
						TriggerClientEvent('esx:showNotification', _source, _U('cannot_pickup_room', item.label))		
						local pickupLabel = ('~y~%s~s~ [~b~%s~s~]'):format(item.label, remaining)
						ESX.OverwritePickup(id, pickup.name, remaining, _source)
					else
						totalItems = totalItems - 1
						pickupTable.items[k] = nil
					end		
				end
				break
			end
		end
		if totalItems <= 0 then
			TriggerClientEvent('esx:removePickup', -1, id)
			ESX.Pickups[id] = nil
		end
	end
end)

RegisterServerEvent('esx:restorePickups')
AddEventHandler('esx:restorePickups', function()
	local _source = source
	for pickupId,pickupTable in pairs(ESX.Pickups) do
		ESX.RestorePickup(pickupId, _source, pickupTable.coords)			
	end
end)

ESX.RegisterServerCallback('esx:getPickupInventory',function(source, cb, coords) 
	cb(ESX.GetPickupInventory(source,coords))
end)
--a packed weapon when used will be added to player equipment
ESX.RegisterUsableItemType('item_weapon_packed', function(source,itemName)
	local xPlayer = ESX.GetPlayerFromId(source)	
	if (not xPlayer.hasWeapon(itemName)) then
		xPlayer.removeInventoryItem(itemName, 1)
		xPlayer.addWeapon(itemName,0)
		TriggerClientEvent('esx:equipWeapon', source, itemName)
	end
end)
--an equipped weapon when used will go back to inventory -- still i must think about ammo
ESX.RegisterUsableItemType('item_weapon', function(source,itemName)
	local xPlayer = ESX.GetPlayerFromId(source)
	xPlayer.addInventoryItem(itemName, 1)
	xPlayer.removeWeapon(itemName, 250)
    TriggerClientEvent('esx:unequipWeapon', source, itemName)
end)
--ammo when used will be loaded to player loadout
ESX.RegisterUsableItemType('item_ammo', function(source,itemName,count)
	local xPlayer = ESX.GetPlayerFromId(source)
	local ammoMax = Config.Ammos[itemName].max	
	local ammoWeapons = Config.Ammos[itemName].weapons
	local currentAmmoCount = 0
	local currentWeapon = nil
	for i=1, #ammoWeapons, 1 do
		if xPlayer.hasWeapon(ammoWeapons[i]) then
			currentWeapon = ammoWeapons[i]
			break
		end
	end
	if currentWeapon ~= nil then
		currentAmmoCount = xPlayer.getAmmo(currentWeapon)
		local maxToLoad = ammoMax - currentAmmoCount
		if (count > maxToLoad and count > 0) then
			count = maxToLoad
		end
		xPlayer.removeInventoryItem(itemName, count)
		xPlayer.addAmmo(itemName,count)
		TriggerClientEvent('esx:equipAmmo', source, itemName)
	end
end)

RegisterServerEvent('esx:unloadAmmo')
AddEventHandler('esx:unloadAmmo', function(itemName,count)
	local xPlayer = ESX.GetPlayerFromId(source)
	local ammoName = ESX.GetAmmoNameByWeapon(itemName)
	local totAmmo = xPlayer.getAmmo(itemName)

	if (count > totAmmo and count > 0) then
		count = totAmmo
	end

	xPlayer.removeAmmoFromWeapon(itemName,count)
	xPlayer.addInventoryItem(ammoName, count)
end)


ESX.RegisterServerCallback('esx:getPlayerData', function(source, cb)
	local xPlayer = ESX.GetPlayerFromId(source)

	cb({
		identifier   = xPlayer.identifier,
		accounts     = xPlayer.getAccounts(),
		inventory    = xPlayer.getInventory(),
		job          = xPlayer.getJob(),
		loadout      = xPlayer.getLoadout(),
		lastPosition = xPlayer.getLastPosition(),
		money        = xPlayer.getMoney()
	})
end)

ESX.RegisterServerCallback('esx:getOtherPlayerData', function(source, cb, target)
	local xPlayer = ESX.GetPlayerFromId(target)

	cb({
		identifier   = xPlayer.identifier,
		accounts     = xPlayer.getAccounts(),
		inventory    = xPlayer.getInventory(),
		job          = xPlayer.getJob(),
		loadout      = xPlayer.getLoadout(),
		lastPosition = xPlayer.getLastPosition(),
		money        = xPlayer.getMoney()
	})
end)

TriggerEvent("es:addGroup", "jobmaster", "user", function(group) end)

ESX.StartDBSync()
ESX.StartPayCheck()
